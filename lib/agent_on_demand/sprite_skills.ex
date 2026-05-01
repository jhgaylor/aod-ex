defmodule AgentOnDemand.SpriteSkills do
  @moduledoc """
  Bundled skills that can be mounted into a sprite at provisioning time.
  Each skill is a directory under `priv/sprite_skills/<name>/`.

  The on-sprite layout differs by runtime:

    * `claude` / `opencode` — drop the directory under
      `~/.claude/skills/<name>/` (opencode reads the same tree natively).
    * `codex` — write a single concatenated `~/.codex/AGENTS.md`.
    * `gemini` — write a single concatenated `~/.gemini/GEMINI.md`.

  The `aod` skill is always mounted on top of whatever the agent requests
  so the callback API works in every conversation.
  """

  alias Sprites.Filesystem

  @bundle_root "sprite_skills"
  @claude_skills_dir "/home/sprite/.claude/skills"
  @codex_agents_md "/home/sprite/.codex/AGENTS.md"
  # gemini runs with HOME=/tmp (so `mv .gemini/projects.json.tmp ...`
  # actually works); its global GEMINI.md must live there. We don't
  # mirror to /home/sprite because gemini reads BOTH and re-registers
  # everything twice on startup.
  @gemini_md_path "/tmp/.gemini/GEMINI.md"

  @always_mounted ["aod"]

  @doc "List all skills bundled in this app."
  def list_bundled do
    case File.ls(priv_dir()) do
      {:ok, entries} ->
        Enum.filter(entries, fn name -> File.dir?(Path.join(priv_dir(), name)) end)

      _ ->
        []
    end
  end

  @doc """
  Mount the requested skills into the sprite using whichever layout the
  runtime expects.

  `runtime` is the runtime string from the agent (`"claude"`, `"codex"`,
  `"gemini"`, or `"opencode"`). Names that don't correspond to a bundled
  skill are silently skipped.
  """
  def mount(sprite, runtime, names \\ []) do
    bundled = list_bundled()
    requested = (names || []) |> Enum.filter(&(&1 in bundled))
    target = (@always_mounted ++ requested) |> Enum.uniq() |> Enum.filter(&(&1 in bundled))

    fs = Sprites.filesystem(sprite, "/")

    case runtime do
      r when r in ["claude", "opencode"] ->
        mount_claude_format(fs, target)

      "codex" ->
        # opencode also reads ~/.claude/skills natively; we still write
        # the claude-style tree for consistency, then overlay AGENTS.md.
        mount_claude_format(fs, target)
        write_concatenated(fs, @codex_agents_md, target)

      "gemini" ->
        mount_claude_format(fs, target)
        write_concatenated(fs, @gemini_md_path, target)

      _ ->
        mount_claude_format(fs, target)
    end

    target
  end

  defp mount_claude_format(fs, target) do
    Filesystem.mkdir_p(fs, @claude_skills_dir)
    Enum.each(target, &mount_one(fs, &1))
  end

  defp mount_one(fs, name) do
    src = Path.join(priv_dir(), name)
    dest = Path.join(@claude_skills_dir, name)
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

  # Concatenate every skill's SKILL.md into a single instruction file at
  # `path`, ensuring the parent directory exists. Skills that don't ship
  # a SKILL.md are skipped.
  defp write_concatenated(fs, path, target) do
    Filesystem.mkdir_p(fs, Path.dirname(path))

    body =
      target
      |> Enum.map(fn name ->
        skill_md = Path.join([priv_dir(), name, "SKILL.md"])

        if File.regular?(skill_md) do
          "<!-- skill: #{name} -->\n" <> File.read!(skill_md)
        else
          ""
        end
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n---\n\n")

    Filesystem.write(fs, path, body)
  end

  defp priv_dir do
    Path.join(:code.priv_dir(:agent_on_demand) |> to_string(), @bundle_root)
  end
end
