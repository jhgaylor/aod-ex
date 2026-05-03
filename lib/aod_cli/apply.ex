defmodule AodCli.Apply do
  @moduledoc """
  Idempotent `aod apply -f <file>`. Reads a multi-document YAML file
  describing AoD `Environment`, `Vault`, and `Agent` resources, and
  reconciles the running instance to match.

  Each resource has a `metadata.name` that's the unique identifier on
  the operator side. We look up the matching record by name via the
  API; if it exists we PUT the spec, if not we POST. Order in the
  file doesn't matter — environments and vaults are always reconciled
  before agents so `spec.environment: <name>` references resolve.

  Resource shape:

      ---
      apiVersion: aod/v1
      kind: Environment | Vault | Agent
      metadata:
        name: <unique-on-operator-side>
      spec:
        # ... fields matching the API schemas ...
        # for Agent: optional `environment: <env-name>` resolves to env id
        # for Environment / Vault: optional `secrets: { KEY: value }` map
        #   upserted as secrets after the row itself is reconciled

  ## Apply-time secret resolution

  So that `aod.yml` can be safely committed, secret values in
  `spec.secrets` accept two kinds of references resolved **at apply
  time** before any DB write:

  - `${VAR}` — substituted from the operator's local env vars or
    `--var KEY=VAL` flags (flags win on collision). `$${VAR}` writes
    a literal `${VAR}`.
  - `op://<vault>/<item>/<field>` — resolved via the 1Password CLI
    (`op`). Auth handled by `op` (biometric, session).
  - `bws://<secret-uuid>` — resolved via the Bitwarden Secrets Manager
    CLI (`bws`). Auth via `BWS_ACCESS_TOKEN` (consumed by `bws`).
  - `infisical://<project?>/<env>/<path?>/<name>` — resolved via the
    Infisical CLI (`infisical`). Empty project segment falls through
    to `.infisical.json` / `INFISICAL_PROJECT_ID`. Auth via the CLI's
    own login session or `INFISICAL_TOKEN`.

  External-reference resolution is dispatched by URI scheme through
  `AodCli.SecretResolvers`. To add another provider (Vault, AWS
  Secrets Manager, Doppler, ...), implement `AodCli.SecretResolver`
  and register the module.

  Both phases collect failures across the whole manifest and exit
  with one message, so the operator fixes their shell exports /
  signs in / sets the access token once.

      Environment:
        secrets:
          GITHUB_TOKEN: ${GH_PAT}                       # local env
          POSTHOG_API_KEY: op://Work/PostHog/api_key    # 1Password
          NPM_TOKEN: bws://abc-123-uuid                 # Bitwarden Secrets Manager
          DATABASE_URL: infisical://abc/prod/api/DATABASE_URL  # Infisical
          ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/key    # ${VAR} first, then op

  Other manifest fields (e.g. agent `mcp_servers` headers) are left
  literal here and resolved by the provision-time substitution layer
  at sprite spawn — separate concern, same `${VAR}` syntax.

  Exit code: 0 on success, 1 if any resource fails to apply.
  """

  alias AgentOnDemand.Substitution
  alias AodCli.Api
  alias AodCli.SecretResolvers

  def dispatch(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [file: :string, var: :keep],
        aliases: [f: :file]
      )

    path =
      opts[:file] ||
        case positional do
          [p | _] -> p
          _ -> AodCli.die("usage: aod apply -f <path-to-yaml> [--var KEY=VAL ...]")
        end

    apply_vars = build_apply_vars(Keyword.get_values(opts, :var))

    docs =
      path
      |> File.read!()
      |> parse_docs!()

    {envs, vaults, agents, unknown} = group(docs)

    if unknown != [] do
      AodCli.die("unsupported kinds in #{path}: " <> Enum.map_join(unknown, ", ", & &1["kind"]))
    end

    {envs, vaults} = expand_apply_secrets(envs, vaults, apply_vars)

    env_id_by_name =
      envs
      |> Enum.reduce(%{}, fn doc, acc ->
        case apply_environment(doc) do
          {:ok, env} -> Map.put(acc, env["name"], env["id"])
          :error -> acc
        end
      end)

    Enum.each(vaults, &apply_vault/1)

    Enum.each(agents, &apply_agent(&1, env_id_by_name))

    :ok
  end

  # Apply-time secret value resolution. Scoped to `spec.secrets` map
  # values on Environment + Vault docs. Two phases run across both
  # lists together so a failure dump shows everything at once instead
  # of trickling out as you fix things.
  #
  #   Phase 1: ${VAR} substitution against the operator's local env
  #            vars + any `--var KEY=VAL` flags (flags win).
  #   Phase 2: `op://vault/item/field` 1Password references — for any
  #            value that comes out of phase 1 starting with `op://`,
  #            shell out to the local `op` CLI to resolve it.
  #
  # Other manifest fields stay literal — those go through provision-
  # time substitution at sprite spawn. Phase 2 only invokes `op` when
  # the manifest actually contains an `op://...` value, so manifests
  # without 1Password references don't require `op` to be installed.
  defp expand_apply_secrets(envs, vaults, vars) do
    n_envs = length(envs)
    all = envs ++ vaults

    all =
      all
      |> run_phase(&substitute_doc_secrets(&1, vars))
      |> die_on_errors(:missing_vars)
      |> run_phase(&resolve_doc_external_refs/1)
      |> die_on_errors(:resolver_failures)

    Enum.split(all, n_envs)
  end

  # Apply `f` to each doc; return either `{:ok, [doc]}` (all succeeded)
  # or `{:error, [{name, details}]}` (collected per-resource).
  defp run_phase(docs, f) do
    {acc_docs, errors} =
      Enum.reduce(docs, {[], []}, fn doc, {acc_docs, errs} ->
        case f.(doc) do
          {:ok, new_doc} -> {[new_doc | acc_docs], errs}
          {:error, name, details} -> {[doc | acc_docs], [{name, details} | errs]}
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(acc_docs)}, else: {:error, Enum.reverse(errors)}
  end

  defp die_on_errors({:ok, docs}, _kind), do: docs

  defp die_on_errors({:error, errors}, kind) do
    AodCli.die(format_phase_errors(kind, errors))
  end

  defp substitute_doc_secrets(doc, vars) do
    case get_in(doc, ["spec", "secrets"]) do
      nil ->
        {:ok, doc}

      %{} = secrets ->
        case Substitution.apply(secrets, vars) do
          {:ok, sub} ->
            {:ok, put_in(doc, ["spec", "secrets"], sub)}

          {:error, {:missing_vars, missing}} ->
            name = get_in(doc, ["metadata", "name"]) || "<unnamed>"
            {:error, name, missing}
        end
    end
  end

  defp resolve_doc_external_refs(doc) do
    case get_in(doc, ["spec", "secrets"]) do
      nil ->
        {:ok, doc}

      %{} = secrets ->
        case resolve_secrets_external_refs(secrets) do
          {:ok, resolved} ->
            {:ok, put_in(doc, ["spec", "secrets"], resolved)}

          {:error, failures} ->
            name = get_in(doc, ["metadata", "name"]) || "<unnamed>"
            {:error, name, failures}
        end
    end
  end

  defp resolve_secrets_external_refs(secrets) do
    {resolved, failures} =
      Enum.reduce(secrets, {%{}, []}, fn {k, v}, {acc, fails} ->
        case SecretResolvers.for_value(v) do
          nil ->
            {Map.put(acc, k, v), fails}

          mod ->
            case mod.read(v) do
              {:ok, plaintext} -> {Map.put(acc, k, plaintext), fails}
              {:error, reason} -> {acc, [{k, v, mod, reason} | fails]}
            end
        end
      end)

    case failures do
      [] -> {:ok, resolved}
      list -> {:error, Enum.reverse(list)}
    end
  end

  defp format_phase_errors(:missing_vars, errors) do
    body =
      Enum.map_join(errors, "\n", fn {name, missing} ->
        "  #{name}: " <> Enum.join(missing, ", ")
      end)

    "apply-time substitution failed — set these in the env or pass --var KEY=VAL:\n" <> body
  end

  defp format_phase_errors(:resolver_failures, errors) do
    body =
      Enum.map_join(errors, "\n", fn {name, failures} ->
        rows =
          Enum.map_join(failures, "\n", fn {k, ref, mod, reason} ->
            "    #{k} (#{ref}): " <> mod.format_error(reason)
          end)

        "  #{name}:\n" <> rows
      end)

    "apply-time secret resolution failed:\n" <> body
  end

  @doc false
  def build_apply_vars(var_args) do
    base = Map.new(System.get_env(), fn {k, v} -> {to_string(k), to_string(v)} end)

    overlays = Map.new(var_args, &parse_var_flag/1)

    Map.merge(base, overlays)
  end

  defp parse_var_flag(s) do
    case String.split(s, "=", parts: 2) do
      [k, v] when k != "" -> {k, v}
      _ -> AodCli.die("--var must be KEY=VALUE, got: #{inspect(s)}")
    end
  end

  # ── parsing ────────────────────────────────────────────────────────

  defp parse_docs!(yaml) do
    case YamlElixir.read_all_from_string(yaml) do
      {:ok, docs} ->
        docs |> Enum.reject(&is_nil/1) |> Enum.reject(&(&1 == %{}))

      {:error, reason} ->
        AodCli.die("yaml parse error: #{inspect(reason)}")
    end
  end

  defp group(docs) do
    Enum.reduce(docs, {[], [], [], []}, fn doc, {envs, vaults, agents, unknown} ->
      case doc["kind"] do
        "Environment" -> {envs ++ [doc], vaults, agents, unknown}
        "Vault" -> {envs, vaults ++ [doc], agents, unknown}
        "Agent" -> {envs, vaults, agents ++ [doc], unknown}
        _ -> {envs, vaults, agents, unknown ++ [doc]}
      end
    end)
  end

  # ── reconciliation ─────────────────────────────────────────────────

  defp apply_environment(doc) do
    name = required(doc, "metadata.name")
    spec = doc["spec"] || %{}
    secrets = spec["secrets"] || %{}

    body =
      spec
      |> Map.delete("secrets")
      |> Map.put("name", name)

    env =
      case fetch_by_name("/environments", name) do
        {:ok, %{"id" => id}} ->
          case Api.put("/environments/#{id}", body) do
            {:ok, %{"data" => env}} ->
              IO.puts("env  ~  #{name}")
              env

            {:error, err} ->
              warn("env  !  #{name} (update failed): #{inspect(err)}")
              nil
          end

        :not_found ->
          case Api.post("/environments", body) do
            {:ok, %{"data" => env}} ->
              IO.puts("env  +  #{name}")
              env

            {:error, err} ->
              warn("env  !  #{name} (create failed): #{inspect(err)}")
              nil
          end
      end

    case env do
      %{"id" => env_id} ->
        upsert_env_secrets(env_id, name, secrets)
        {:ok, env}

      _ ->
        :error
    end
  end

  defp upsert_env_secrets(_, _, secrets) when secrets in [nil, %{}], do: :ok

  defp upsert_env_secrets(env_id, name, %{} = secrets) do
    Enum.each(secrets, fn {k, v} ->
      case Api.post("/environments/#{env_id}/secrets", %{
             key: to_string(k),
             value: to_string(v)
           }) do
        {:ok, _} -> IO.puts("  secret  ~  #{name}/#{k}")
        {:error, err} -> warn("  secret  !  #{name}/#{k}: #{inspect(err)}")
      end
    end)
  end

  defp apply_vault(doc) do
    name = required(doc, "metadata.name")
    spec = doc["spec"] || %{}
    secrets = spec["secrets"] || %{}

    body =
      spec
      |> Map.delete("secrets")
      |> Map.put("name", name)

    vault =
      case fetch_by_name("/vaults", name) do
        {:ok, %{"id" => id} = existing} ->
          case Api.put("/vaults/#{id}", body) do
            {:ok, %{"data" => v}} ->
              IO.puts("vault  ~  #{name}")
              v

            {:error, err} ->
              warn("vault  !  #{name} (update failed): #{inspect(err)}")
              existing
          end

        :not_found ->
          case Api.post("/vaults", body) do
            {:ok, %{"data" => v}} ->
              IO.puts("vault  +  #{name}")
              v

            {:error, err} ->
              warn("vault  !  #{name} (create failed): #{inspect(err)}")
              nil
          end
      end

    case vault do
      %{"id" => vault_id} -> upsert_vault_secrets(vault_id, name, secrets)
      _ -> :error
    end
  end

  defp upsert_vault_secrets(_, _, secrets) when secrets in [nil, %{}], do: :ok

  defp upsert_vault_secrets(vault_id, name, %{} = secrets) do
    Enum.each(secrets, fn {k, v} ->
      case Api.post("/vaults/#{vault_id}/secrets", %{key: to_string(k), value: to_string(v)}) do
        {:ok, _} -> IO.puts("  secret  ~  #{name}/#{k}")
        {:error, err} -> warn("  secret  !  #{name}/#{k}: #{inspect(err)}")
      end
    end)
  end

  defp apply_agent(doc, env_id_by_name) do
    name = required(doc, "metadata.name")
    spec = doc["spec"] || %{}

    spec =
      case spec["environment"] do
        nil ->
          Map.delete(spec, "environment")

        env_name when is_binary(env_name) ->
          case Map.fetch(env_id_by_name, env_name) do
            {:ok, env_id} ->
              spec
              |> Map.delete("environment")
              |> Map.put("environment_id", env_id)

            :error ->
              warn(
                "agent  ?  #{name}: environment '#{env_name}' not in this manifest, skipping reference"
              )

              Map.delete(spec, "environment")
          end
      end

    body = Map.put(spec, "name", name)

    case fetch_by_name("/agents", name) do
      {:ok, %{"id" => id}} ->
        case Api.put("/agents/#{id}", body) do
          {:ok, _} ->
            IO.puts("agent  ~  #{name}")
            :ok

          {:error, err} ->
            warn("agent  !  #{name} (update failed): #{inspect(err)}")
            :error
        end

      :not_found ->
        case Api.post("/agents", body) do
          {:ok, _} ->
            IO.puts("agent  +  #{name}")
            :ok

          {:error, err} ->
            warn("agent  !  #{name} (create failed): #{inspect(err)}")
            :error
        end
    end
  end

  # ── lookup helpers ─────────────────────────────────────────────────

  defp fetch_by_name(collection_path, name) do
    case Api.get(collection_path) do
      {:ok, %{"data" => data}} when is_list(data) ->
        case Enum.find(data, &(&1["name"] == name)) do
          nil -> :not_found
          row -> {:ok, row}
        end

      {:error, err} ->
        AodCli.die("GET #{collection_path} failed: #{inspect(err)}")
    end
  end

  defp required(doc, "metadata.name") do
    case get_in(doc, ["metadata", "name"]) do
      n when is_binary(n) and n != "" -> n
      _ -> AodCli.die("resource missing required `metadata.name`: #{inspect(doc)}")
    end
  end

  defp warn(msg), do: IO.puts(:stderr, msg)
end
