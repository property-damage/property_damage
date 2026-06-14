defmodule ObanBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :oban_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ObanBench.Application, []}
    ]
  end

  defp deps do
    [
      {:property_damage, path: "../.."},
      {:oban, "~> 2.18"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"}
    ]
  end

  # Friction-free DB lifecycle: `mix test` brings the dedicated Postgres
  # container up (idempotent: a no-op when it is already healthy), creates
  # and migrates the database, then runs. Tear down explicitly with
  # `mix bench.db.down` when you are done. If PD_OBAN_DATABASE_URL is set
  # (e.g. in CI with a service container), the container step is skipped and
  # the bench points at that database instead.
  defp aliases do
    [
      "bench.db.up": [
        "cmd sh -c 'test -n \"$PD_OBAN_DATABASE_URL\" || docker compose up -d --wait'"
      ],
      "bench.db.down": ["cmd docker compose down -v"],
      test: ["bench.db.up", "ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
