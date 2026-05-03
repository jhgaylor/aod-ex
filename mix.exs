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
      version: "0.2.2",
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
        # CrossVersionNifCopy still needed: OTP-bundled NIFs (crypto,
        # asn1) drift versions between the build host and target ERTS,
        # and stock CopyERTS only overwrites on exact-version match.
        burrito:
          Keyword.merge(burrito_targets(skip_nifs: true),
            extra_steps: [
              fetch: [pre: [AoD.Burrito.InjectMuslPath]],
              patch: [post: [AoD.Burrito.CrossVersionNifCopy]]
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
        burrito: burrito_targets_with_nif_workarounds()
      ]
    ]
  end

  defp burrito_targets(opts \\ []) do
    skip_nifs = Keyword.get(opts, :skip_nifs, false)

    [
      targets: [
        linux: [
          os: :linux,
          cpu: :x86_64,
          custom_erts:
            "https://beam-machine-universal.b-cdn.net/OTP-28.4/linux/x86_64/any/otp_28.4_linux_any_x86_64.tar.gz?openssl=3.5.1&musl=1.2.5",
          skip_nifs: skip_nifs
        ],
        macos: [
          os: :darwin,
          cpu: :aarch64,
          custom_erts:
            "https://beam-machine-universal.b-cdn.net/OTP-28.4/macos/universal/otp_28.4_macos_universal.tar.gz?openssl=3.5.1&musl=1.2.5",
          skip_nifs: skip_nifs
        ]
      ],
      debug: Mix.env() != :prod
    ]
  end

  defp burrito_targets_with_nif_workarounds do
    Keyword.merge(burrito_targets(),
      extra_steps: [
        fetch: [pre: [AoD.Burrito.InjectMuslPath]],
        patch: [post: [AoD.Burrito.CrossVersionNifCopy]]
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
