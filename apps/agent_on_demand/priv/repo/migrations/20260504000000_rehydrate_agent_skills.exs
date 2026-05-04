defmodule AgentOnDemand.Repo.Migrations.RehydrateAgentSkills do
  @moduledoc """
  `agents.skills` switched from a list of bundled-skill names to a list of
  inline/github SkillSpec objects (see `AgentOnDemand.Agents.Agent`).

  In SQLite both shapes are stored as TEXT JSON in the same column, so no
  DDL change is needed. This migration just rewrites the JSON contents:

    * If `metadata.legacy_skills` is set (populated by `mix aod.import`
      from the old Python AoD shape), translate each `{type, source, name?}`
      entry into the new `{source, name?}` shape.
    * Otherwise, set skills to `[]`. Any pre-migration string entries
      (e.g. `["aod"]`) are dropped — `aod` is now always-prepended by the
      provisioner so this is a safe no-op.
  """
  use Ecto.Migration

  def up do
    repo = repo()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "SELECT id, skills, metadata FROM agents", [])

    for [id, skills_json, meta_json] <- rows do
      meta = decode(meta_json) || %{}
      legacy = Map.get(meta, "legacy_skills", [])

      new_skills =
        case legacy do
          list when is_list(list) and list != [] ->
            list
            |> Enum.map(&translate_legacy/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            case decode(skills_json) do
              list when is_list(list) ->
                Enum.flat_map(list, fn
                  s when is_binary(s) -> []
                  m when is_map(m) -> [m]
                  _ -> []
                end)

              _ ->
                []
            end
        end

      new_meta = Map.delete(meta, "legacy_skills")

      Ecto.Adapters.SQL.query!(
        repo,
        "UPDATE agents SET skills = ?, metadata = ? WHERE id = ?",
        [Jason.encode!(new_skills), Jason.encode!(new_meta), id]
      )
    end
  end

  def down do
    Ecto.Adapters.SQL.query!(repo(), "UPDATE agents SET skills = '[]'", [])
  end

  defp decode(nil), do: nil
  defp decode(""), do: nil

  defp decode(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  defp translate_legacy(%{"source" => source} = entry) when is_binary(source) do
    name = Map.get(entry, "name")

    if is_binary(name) and name != "" do
      %{"source" => source, "name" => name}
    else
      %{"source" => source}
    end
  end

  defp translate_legacy(_), do: nil
end
