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

  ## Apply-time substitution

  So that `aod.yml` can be safely committed, `${VAR}` references in
  `spec.secrets` values are resolved **at apply time** from the
  operator's local environment and any `--var KEY=VAL` flags (flags
  win on collision). Use `$${VAR}` for the literal `${VAR}`. The
  resolved value is what lands in the DB.

      Environment:
        secrets:
          GITHUB_TOKEN: ${GH_PAT}     # ← resolved from $GH_PAT at apply time

  Other manifest fields (e.g. agent `mcp_servers` headers) are left
  literal here and resolved by the provision-time substitution layer
  at sprite spawn — separate concern.

  Missing references abort the apply with every name listed at once,
  so you can `export` them all and re-run.

  Exit code: 0 on success, 1 if any resource fails to apply.
  """

  alias AgentOnDemand.Substitution
  alias AodCli.Api

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

    envs = expand_apply_secrets(envs, apply_vars)
    vaults = expand_apply_secrets(vaults, apply_vars)

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

  # Apply-time substitution. Scoped to `spec.secrets` map values on
  # Environment + Vault docs. Resolves `${VAR}` from the operator's
  # local env vars + any `--var KEY=VAL` flags (flags win on
  # collision). Other manifest fields are left literal — those go
  # through provision-time substitution at sprite spawn.
  #
  # If any doc references an unresolvable name, we collect all of them
  # across the manifest and exit with a single message so the operator
  # fixes their shell exports in one pass.
  defp expand_apply_secrets(docs, vars) do
    {expanded, errors} =
      Enum.reduce(docs, {[], []}, fn doc, {acc_docs, acc_errors} ->
        case substitute_doc_secrets(doc, vars) do
          {:ok, new_doc} -> {[new_doc | acc_docs], acc_errors}
          {:error, name, missing} -> {[doc | acc_docs], [{name, missing} | acc_errors]}
        end
      end)

    if errors != [] do
      AodCli.die(format_apply_errors(errors))
    end

    Enum.reverse(expanded)
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

  defp format_apply_errors(errors) do
    body =
      errors
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {name, missing} ->
        "  #{name}: " <> Enum.join(missing, ", ")
      end)

    "apply-time substitution failed — set these in the env or pass --var KEY=VAL:\n" <> body
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
