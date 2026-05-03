defmodule AodClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :aod_client,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir client for the Agent on Demand API",
      package: package()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md)
    ]
  end
end
