defmodule AoD.Burrito.InjectMuslPath do
  @moduledoc """
  Workaround for Burrito + custom_erts URL on Linux.

  Stock `Burrito.Steps.Fetch.FetchMusl` only runs when erts_source matches
  `{:precompiled, _}`. We use `custom_erts: <beam-machine URL>` to pin OTP
  28.4 (because beam-machine doesn't have OTP 28.5 prebuilt yet), which
  becomes `{:url, ...}`. FetchMusl skips, so:
    - `__BURRITO_MUSL_RUNTIME_PATH` is empty (wrapper skips musl install)
    - `deps/burrito/src/musl-runtime.so` is missing (wrapper won't compile)

  This step replicates FetchMusl's behavior unconditionally for linux targets.
  """
  @behaviour Burrito.Builder.Step

  alias Burrito.Builder.Context
  alias Burrito.Builder.Log
  alias Burrito.Builder.Target
  alias Burrito.Util.FileCache

  @musl_url "https://beam-machine-universal.b-cdn.net/musl/libc-musl-{HASH}.so?please-respect-my-bandwidth-costs=thank-you"
  @hashes %{
    x86_64: "71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb",
    aarch64: "6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e"
  }

  @impl Burrito.Builder.Step
  def execute(%Context{target: %Target{os: :linux, cpu: cpu}} = ctx) do
    hash = Map.fetch!(@hashes, cpu)
    so_url = String.replace(@musl_url, "{HASH}", hash)
    cache_key = :crypto.hash(:sha, so_url) |> Base.encode16()

    so_bytes =
      case FileCache.fetch(cache_key) do
        {:hit, data} ->
          Log.info(:step, "Found cached musl runtime, using that")
          data

        _ ->
          Log.info(:step, "Downloading musl runtime: #{so_url}")
          {:ok, _} = Application.ensure_all_started(:req)
          %{status: 200, body: body} = Req.get!(so_url, raw: true)
          FileCache.put_if_not_exist(cache_key, body)
          body
      end

    out_path = Path.join([ctx.self_dir, "src", "musl-runtime.so"])
    File.write!(out_path, so_bytes)
    Log.success(:step, "Wrote musl runtime: #{out_path}")

    %Context{
      ctx
      | extra_build_env:
          ctx.extra_build_env ++
            [{"__BURRITO_MUSL_RUNTIME_PATH", "/tmp/libc-musl-#{hash}.so"}]
    }
  end

  def execute(ctx), do: ctx
end
