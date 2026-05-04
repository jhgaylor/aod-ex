defmodule Mix.Tasks.Aod.Import do
  @moduledoc """
  Import a YAML dump from the legacy Python AoD into this Elixir AoD's database.

  Usage:
      mix aod.import priv/seeds/aod-dump-2026-04.yaml --dry-run
      mix aod.import priv/seeds/aod-dump-2026-04.yaml

  - `--dry-run` prints the canonical insert payloads (and any warnings) but
    doesn't touch the database. Run this first.
  - Without `--dry-run`, inserts everything in a single transaction. Existing
    rows with matching ids are skipped (idempotent).

  Mappings & known data loss:
    * `environment.networking.type` → `networking_type` (the rest of
      networking is dropped; there's nothing else in the dump).
    * `environment.setup_script: null` → `""`.
    * `agent.skills` (legacy `{type: "github", source, name?}` entries) is
      translated 1:1 into the new schema's SkillSpec shape (`{source, name?}`).
      Non-github legacy entries (none observed in dumps so far) are dropped
      with a warning.
    * `agent.mcp_servers` (list) → map keyed by `name`. Entries with empty
      `name` are dropped.
    * `agent.metadata.nebula_*` and `relay_workspace_id` are preserved
      under `metadata.legacy_metadata`.
    * Hardcoded bearer tokens in MCP `headers.Authorization` are passed
      through as-is. They will be written into ~/.claude.json on each sprite
      and used by claude. Rotate these before production. (Long-term: lift
      to first-class secrets with template substitution.)
  """
  use Mix.Task

  alias AgentOnDemand.Agents.Agent
  alias AgentOnDemand.Environments.Environment
  alias AgentOnDemand.Repo

  @shortdoc "Import a legacy AoD YAML dump"

  @impl Mix.Task
  def run(args) do
    {opts, [path], _} = OptionParser.parse(args, strict: [dry_run: :boolean])
    dry_run = opts[:dry_run] || false

    Mix.Task.run("app.start")

    {:ok, doc} = YamlElixir.read_from_file(path)

    raw_envs = doc["environments"] || []
    raw_agents = doc["agents"] || []

    envs = Enum.map(raw_envs, &transform_env/1)
    agents = Enum.map(raw_agents, &transform_agent/1)
    warnings = collect_warnings(raw_agents, raw_envs)

    print_summary(envs, agents, warnings)

    if dry_run do
      Mix.shell().info("\n[dry-run] no rows were written.")
    else
      Repo.transaction(fn ->
        Enum.each(envs, &upsert(:env, &1))
        Enum.each(agents, &upsert(:agent, &1))
      end)

      Mix.shell().info("\nimported #{length(envs)} environments + #{length(agents)} agents.")
    end
  end

  # ── transformers ──────────────────────────────────────────────────────────

  defp transform_env(e) do
    %{
      id: e["id"],
      name: e["name"],
      packages: e["packages"] || %{},
      env_vars: %{},
      setup_script: e["setup_script"] || "",
      networking_type: get_in(e, ["networking", "type"]) || "unrestricted",
      networking_config: %{}
    }
  end

  defp transform_agent(a) do
    legacy_meta = a["metadata"] || %{}

    metadata =
      %{}
      |> maybe_put("legacy_metadata", legacy_meta, &(map_size(&1) > 0))

    %{
      id: a["id"],
      name: a["name"],
      description: a["description"] || "",
      system: a["system"] || "",
      model: a["model"],
      runtime: a["runtime"],
      environment_id: a["environment_id"],
      skills: transform_skills(a["skills"] || []),
      mcp_servers: transform_mcp(a["mcp_servers"] || []),
      metadata: metadata
    }
  end

  # Legacy shape: list of `{type: "github", source, name?, description?}`.
  # New shape: list of `{source, name?}` (or inline `{name, content}`, but
  # the legacy dump never carries inline). Drop the redundant `type` and
  # any `description` field, since the new schema doesn't store it.
  defp transform_skills(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"type" => "github", "source" => source} = entry when is_binary(source) ->
        case entry["name"] do
          n when is_binary(n) and n != "" -> [%{"source" => source, "name" => n}]
          _ -> [%{"source" => source}]
        end

      _ ->
        []
    end)
  end

  defp transform_skills(_), do: []

  defp transform_mcp(servers) when is_list(servers) do
    servers
    |> Enum.reject(fn s -> blank?(Map.get(s, "name")) end)
    |> Map.new(fn s ->
      name = s["name"]
      entry = build_mcp_entry(s)
      {name, entry}
    end)
  end

  defp transform_mcp(_), do: %{}

  defp build_mcp_entry(%{"type" => "url", "url" => url} = s) do
    %{"type" => "http", "url" => url}
    |> maybe_put("headers", clean_headers(s["headers"]), &(map_size(&1) > 0))
  end

  defp build_mcp_entry(%{"type" => "stdio", "command" => cmd} = s) do
    %{"type" => "stdio", "command" => cmd, "args" => s["args"] || []}
    |> maybe_put("env", s["env"] || %{}, &(map_size(&1) > 0))
  end

  defp build_mcp_entry(s), do: s

  defp clean_headers(nil), do: %{}

  defp clean_headers(%{} = h) do
    h
    |> Enum.reject(fn {k, v} -> blank?(k) or blank?(v) end)
    |> Map.new()
  end

  defp clean_headers(_), do: %{}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp maybe_put(map, key, value, predicate) do
    if predicate.(value), do: Map.put(map, key, value), else: map
  end

  # ── warnings ──────────────────────────────────────────────────────────────

  defp collect_warnings(agents, envs) do
    env_ids = MapSet.new(envs, & &1["id"])
    agent_warnings = Enum.flat_map(agents, &warn_agent(&1, env_ids))

    {token_warnings, leaked_tokens} =
      agents
      |> Enum.flat_map(&extract_leaked_tokens/1)
      |> Enum.uniq()
      |> case do
        [] -> {[], []}
        ts -> {["#{length(ts)} unique bearer token(s) embedded in MCP headers"], ts}
      end

    %{
      messages: agent_warnings ++ token_warnings,
      leaked_tokens: leaked_tokens
    }
  end

  defp warn_agent(a, env_ids) do
    [
      if(a["environment_id"] && !MapSet.member?(env_ids, a["environment_id"]),
        do: "agent #{a["name"]}: env_id #{a["environment_id"]} not in dump"
      ),
      if(non_github_skills?(a["skills"]),
        do: "agent #{a["name"]}: dropped non-github legacy skill entry"
      ),
      if(empty_name_mcp?(a["mcp_servers"]),
        do: "agent #{a["name"]}: dropped MCP server(s) with empty name"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp empty_name_mcp?(servers) when is_list(servers) do
    Enum.any?(servers, fn s -> blank?(Map.get(s, "name")) end)
  end

  defp empty_name_mcp?(_), do: false

  defp non_github_skills?(list) when is_list(list) do
    Enum.any?(list, fn
      %{"type" => "github"} -> false
      m when is_map(m) -> true
      _ -> true
    end)
  end

  defp non_github_skills?(_), do: false

  defp extract_leaked_tokens(%{"mcp_servers" => servers}) when is_list(servers) do
    Enum.flat_map(servers, fn s ->
      case get_in(s, ["headers", "Authorization"]) do
        "Bearer " <> tok -> [tok]
        _ -> []
      end
    end)
  end

  defp extract_leaked_tokens(_), do: []

  # ── upserts ───────────────────────────────────────────────────────────────

  defp upsert(:env, attrs) do
    case Repo.get(Environment, attrs.id) do
      nil ->
        struct(Environment, attrs)
        |> Map.put(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
        |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.insert!()

      existing ->
        Mix.shell().info("  skip env #{attrs.name} (already present)")
        existing
    end
  end

  defp upsert(:agent, attrs) do
    case Repo.get(Agent, attrs.id) do
      nil ->
        struct(Agent, attrs)
        |> Map.put(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
        |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.insert!()

      existing ->
        Mix.shell().info("  skip agent #{attrs.name} (already present)")
        existing
    end
  end

  # ── pretty-print ──────────────────────────────────────────────────────────

  defp print_summary(envs, agents, warnings) do
    Mix.shell().info("=" |> String.duplicate(72))
    Mix.shell().info("Environments (#{length(envs)})")
    Mix.shell().info("=" |> String.duplicate(72))

    for e <- envs do
      Mix.shell().info(
        "  #{String.pad_trailing(e.name, 28)} #{e.networking_type}  setup=#{inspect(e.setup_script)}  packages=#{inspect(e.packages)}"
      )
    end

    Mix.shell().info("\n" <> ("=" |> String.duplicate(72)))
    Mix.shell().info("Agents (#{length(agents)})")
    Mix.shell().info("=" |> String.duplicate(72))

    for a <- agents do
      env_label = if a.environment_id, do: short(a.environment_id), else: "(none)"
      mcp_names = a.mcp_servers |> Map.keys() |> Enum.join(",")

      Mix.shell().info(
        "  #{String.pad_trailing(a.name, 26)} #{String.pad_trailing(a.runtime, 8)} #{String.pad_trailing(a.model, 32)} env=#{env_label} mcp=[#{mcp_names}] skills=#{length(a.skills)}"
      )
    end

    if warnings.messages != [] do
      Mix.shell().info("\n" <> ("=" |> String.duplicate(72)))
      Mix.shell().info("Warnings")
      Mix.shell().info("=" |> String.duplicate(72))
      for w <- warnings.messages, do: Mix.shell().info("  • " <> w)
    end

    if warnings.leaked_tokens != [] do
      Mix.shell().info("\n" <> ("=" |> String.duplicate(72)))
      Mix.shell().info("Bearer tokens that will be passed through into ~/.claude.json")
      Mix.shell().info("=" |> String.duplicate(72))
      for t <- warnings.leaked_tokens, do: Mix.shell().info("  • " <> redact(t))

      Mix.shell().info(
        "  (rotate these before exposing the new system; consider lifting to env secrets)"
      )
    end
  end

  defp short(id) when is_binary(id), do: binary_part(id, 0, 8)
  defp short(_), do: "?"

  defp redact(token) when is_binary(token) and byte_size(token) > 12 do
    binary_part(token, 0, 6) <> "…" <> binary_part(token, byte_size(token) - 4, 4)
  end

  defp redact(t), do: t
end
