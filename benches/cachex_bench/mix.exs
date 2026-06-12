defmodule CachexBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :cachex_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:property_damage, path: "../.."},
      {:cachex, "~> 4.1"}
    ]
  end
end
