defmodule AoD.Burrito.CrossVersionNifCopy do
  @moduledoc """
  Workaround for Burrito's `CopyERTS` step when local OTP doesn't match the
  target ERTS version.

  Stock `CopyERTS` overwrites NIFs only when the lib dir name matches exactly
  (e.g. `lib/crypto-5.8.2/priv/lib/crypto.so`). If the assembled release has
  `crypto-5.8.3` (because we built locally on a different OTP) and the
  downloaded target ERTS has `crypto-5.8.2`, the target NIF lands in a
  parallel `lib/crypto-5.8.2/` dir and the runtime still loads from
  `lib/crypto-5.8.3/` — which holds the wrong-platform NIF — and dies with
  `Exec format error` (Linux) or `Function not found …` (macOS, when the
  NIF interface itself drifts between OTP versions).

  This step copies each NIF (`.so` for Linux, `.dylib` for macOS) in the
  unpacked target ERTS into every matching `<app>-*` dir in the release,
  matching by app name rather than exact version.

  Retired by aligning local OTP to the target ERTS version. See `docs/deploy.md`.
  """
  @behaviour Burrito.Builder.Step

  alias Burrito.Builder.Context
  alias Burrito.Builder.Target
  alias Burrito.Builder.Log

  @nif_extensions [".so", ".dylib"]

  @impl Burrito.Builder.Step
  def execute(%Context{target: %Target{erts_source: {:local_unpacked, [path: erts_path]}}} = ctx) do
    src_libs =
      [erts_path, "**", "lib", "*-*", "priv", "lib", "*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&(Path.extname(&1) in @nif_extensions))

    dest_lib_root = Path.join(ctx.work_dir, "lib") |> Path.expand()

    Enum.each(src_libs, fn src ->
      app_with_vsn = src |> Path.relative_to(erts_path) |> Path.split() |> Enum.at(-4)
      [app | _] = String.split(app_with_vsn, "-")
      lib_name = Path.basename(src)

      matching_dirs = dest_lib_root |> Path.join("#{app}-*") |> Path.wildcard()

      for dir <- matching_dirs, Path.basename(dir) != app_with_vsn do
        dest = Path.join([dir, "priv", "lib", lib_name])
        File.mkdir_p!(Path.dirname(dest))
        _ = File.rm(dest)
        File.copy!(src, dest)
        File.chmod!(dest, 0o755)

        Log.warning(
          :step,
          "Cross-version NIF: #{lib_name} #{app_with_vsn} -> #{Path.basename(dir)}"
        )
      end
    end)

    ctx
  end

  def execute(ctx), do: ctx
end
