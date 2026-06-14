defmodule RedisBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :redis_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets]
    ]
  end

  defp deps do
    [
      {:property_damage, path: "../.."},
      {:redix, "~> 1.5"}
    ]
  end

  # Friction-free infra lifecycle: `mix test` brings the dedicated Redis +
  # Toxiproxy stack up (idempotent: a no-op when already healthy), then runs.
  # Tear down explicitly with `mix bench.db.down` when you are done. If
  # PD_REDIS_URL is set (e.g. in CI with service containers), the container
  # step is skipped and the bench points at that endpoint instead.
  defp aliases do
    [
      "bench.db.up": [
        "cmd sh -c 'test -n \"$PD_REDIS_URL\" || docker compose up -d --wait'"
      ],
      "bench.db.down": ["cmd docker compose down -v"],
      test: ["bench.db.up", "test"]
    ]
  end
end
