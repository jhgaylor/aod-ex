defmodule AgentOnDemand.SpriteSkills do
  @moduledoc """
  Bundled skills that can be mounted into a sprite at provisioning time.
  Each skill is a directory under `priv/sprite_skills/<name>/`. Mounted to
  `/home/sprite/.claude/skills/<name>/` (matching Claude Code's skills layout).
  """

  alias Sprites.Filesystem

  @bundle_root "sprite_skills"
  @sprite_skills_dir "/home/sprite/.claude/skills"

  @doc "List all skills bundled in this app."
  def list_bundled do
    case File.ls(priv_dir()) do
      {:ok, entries} ->
        Enum.filter(entries, fn name ->
          File.dir?(Path.join(priv_dir(), name))
        end)

      _ ->
        []
    end
  end

  # The "aod" skill gives the agent the API + token to spawn more
  # conversations. We always mount it so the callback path works
  # regardless of what the agent's `skills` list says.
  @always_mounted ["aod"]

  @doc """
  Mount the requested skills into the sprite. The system-level `aod` skill
  is always mounted on top of whatever's requested. Names that don't
  correspond to a bundled skill are silently skipped.
  """
  def mount(sprite, names \\ []) do
    bundled = list_bundled()
    requested = (names || []) |> Enum.filter(&(&1 in bundled))
    target = (@always_mounted ++ requested) |> Enum.uniq() |> Enum.filter(&(&1 in bundled))

    fs = Sprites.filesystem(sprite, "/")
    Filesystem.mkdir_p(fs, @sprite_skills_dir)

    Enum.each(target, fn name ->
      mount_one(fs, name)
    end)

    target
  end

  defp mount_one(fs, name) do
    src = Path.join(priv_dir(), name)
    dest = Path.join(@sprite_skills_dir, name)
    Filesystem.mkdir_p(fs, dest)

    src
    |> File.ls!()
    |> Enum.each(fn entry ->
      src_path = Path.join(src, entry)

      if File.regular?(src_path) do
        content = File.read!(src_path)
        Filesystem.write(fs, Path.join(dest, entry), content)
      end
    end)
  end

  defp priv_dir do
    Path.join(:code.priv_dir(:agent_on_demand) |> to_string(), @bundle_root)
  end
end
