defmodule KratosBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :kratos_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:property_damage, path: "../.."},
      {:req, "~> 0.5"},
      # The mock third party is an HTTP server the bench runs on the host: Ory
      # Kratos calls it as a blocking registration web_hook. Bandit/Plug host it.
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"}
    ]
  end

  # Friction-free infra lifecycle, mirroring the other benches. `mix test` brings
  # up a single, dedicated, ephemeral Ory Kratos container (idempotent: a no-op
  # when already healthy) and then runs. Kratos uses an in-memory DSN, so no DB
  # sidecar is needed; state is reset per sequence by the adapter (admin API).
  #
  # Tear down explicitly with `mix bench.db.down`. If PD_KRATOS_PUBLIC_URL and
  # PD_KRATOS_ADMIN_URL are set (e.g. a BYO Kratos), the container step is
  # skipped and the bench points at those endpoints instead.
  defp aliases do
    [
      "bench.db.up": ["cmd ./scripts/bench_up.sh"],
      "bench.db.down": ["cmd docker compose down -v"],
      test: ["bench.db.up", "test"]
    ]
  end
end
