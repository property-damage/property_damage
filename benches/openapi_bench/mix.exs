defmodule OpenapiBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :openapi_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:property_damage, path: "../.."},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"}
    ]
  end
end
