defmodule AoD.Umbrella.MixProject do
  @moduledoc """
  Umbrella project. Two child apps:

    * `apps/aod_cli/`    — the operator-side CLI (also embeds the
      apply pipeline, `aod up`, `aod down`, etc.). Self-contained:
      no Phoenix, no Ecto, no Horde — just HTTP + parsing + Sprites.
    * `apps/aod_server/` — the AoD server (Phoenix + LiveView + Ecto +
      Horde + OpenTelemetry). What `aod up` deploys into a Sprite.

  Two Burrito releases produce four binaries on every release tag:

    * `aod` (small, CLI) → `aod-{linux-x86_64,macos-aarch64}`
    * `aod_server`       → `aod-server-{linux-x86_64,macos-aarch64}`

  `aod up` pushes the linux server binary into a Sprite; the macOS CLI
  binary is what operators run on their own laptop without Erlang
  installed.
  """
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.2.15",
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:burrito, "~> 1.5", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      aod: [
        # CLI release. `aod_cli`'s OTP app starts AodCli.Bootstrap which
        # reads argv, dispatches AodCli.main/1, and halts.
        applications: [aod_cli: :permanent, runtime_tools: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        # `skip_nifs: true` — CLI has no deps NIFs to recompile
        # (jason / req / yaml_elixir / sprites are all pure-elixir);
        # avoids Burrito iterating sibling-app deps like exqlite that
        # aren't in this release.
        burrito:
          Keyword.merge(burrito_targets(skip_nifs: true),
            extra_steps: [
              fetch: [pre: [AoD.Burrito.InjectMuslPath]]
            ]
          )
      ],
      aod_server: [
        # Full Phoenix release. Also bundles aod_cli (for AodCli.Substitution
        # at provision time). Both apps are :permanent — Mix won't allow
        # a :permanent app to depend on a :load-only app. AodCli.Bootstrap
        # is gated on `:run_main_on_start` config, which the umbrella's
        # runtime.exs only sets when RELEASE_NAME=aod.
        applications: [aod_cli: :permanent, agent_on_demand: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: burrito_targets_with_musl_fix()
      ]
    ]
  end

  defp burrito_targets(opts \\ []) do
    skip_nifs = Keyword.get(opts, :skip_nifs, false)

    # Linux: the OTP libraries (crypto.so etc.) come from the BUILD
    # HOST's local OTP install at `mix release` time — `custom_erts:`
    # only swaps the ERTS runtime, not the application NIFs. The build
    # host MUST therefore be musl (Alpine), or crypto.so ends up
    # glibc-built and fails to load on Sprites with
    # `__memcpy_chk: symbol not found`. CI runs the linux build inside
    # `hexpm/elixir:*-alpine-*`. No `custom_erts:` here — the ERTS
    # bundled is the host's own musl ERTS, guaranteed compatible with
    # the bundled OTP libs.
    #
    # macOS: cross-compiled from a Linux runner. Burrito needs the full
    # Mach-O OTP, which the host can't produce — so we point
    # `custom_erts:` at our self-hosted vendor release (immutable
    # mirror of beam-machine's tarball; see vendor-erts-otp-28.4).
    all_targets = [
      linux: [
        os: :linux,
        cpu: :x86_64,
        skip_nifs: skip_nifs
      ],
      macos: [
        os: :darwin,
        cpu: :aarch64,
        custom_erts:
          "https://github.com/jhgaylor/aod-ex/releases/download/vendor-erts-otp-28.4/otp_28.4_macos_universal.tar.gz",
        skip_nifs: skip_nifs
      ]
    ]

    selected =
      case System.get_env("BURRITO_TARGETS") do
        nil ->
          all_targets

        "" ->
          all_targets

        list ->
          keys =
            list
            |> String.split(",", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.map(&String.to_atom/1)

          Keyword.take(all_targets, keys)
      end

    [
      targets: selected,
      debug: Mix.env() != :prod
    ]
  end

  defp burrito_targets_with_musl_fix do
    Keyword.merge(burrito_targets(),
      extra_steps: [
        fetch: [pre: [AoD.Burrito.InjectMuslPath]]
      ]
    )
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --app agent_on_demand mix ecto.setup"],
      "ecto.reset": ["cmd --app agent_on_demand mix ecto.reset"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict --mute-exit-status",
        "test"
      ]
    ]
  end
end
