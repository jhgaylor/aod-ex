defmodule AodCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :aod_cli,
      version: "0.2.13",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [
        main_module: AodCli,
        name: "aod",
        app: nil,
        embed_elixir: true
      ]
    ]
  end

  def application do
    [
      mod: {AodCli.Bootstrap, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.11"},
      {:sprites, path: "../../../sprites-ex"},
      # Build-time only — bootstrap reads argv via Burrito.Util.Args
      # when running inside the wrapped binary.
      {:burrito, "~> 1.5", runtime: false}
    ]
  end
end
