import Config

config :oban_bench, ecto_repos: [ObanBench.Repo]

# Connection: a DATABASE_URL wins (CI service container / BYO Postgres),
# otherwise the dedicated docker-compose container on PD_OBAN_PG_PORT.
case System.get_env("PD_OBAN_DATABASE_URL") do
  url when is_binary(url) and url != "" ->
    config :oban_bench, ObanBench.Repo, url: url, pool_size: 30

  _ ->
    config :oban_bench, ObanBench.Repo,
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      database: "pd_oban_bench",
      port: String.to_integer(System.get_env("PD_OBAN_PG_PORT", "5434")),
      pool_size: 30
end

# Staging (scheduled/retryable -> available) is built into Oban's core in
# 2.23, so no Stager plugin is needed. Pruning is left off so completed jobs
# persist for the resource pollers to observe.
config :oban_bench, Oban,
  repo: ObanBench.Repo,
  queues: [bench: 10],
  plugins: false

config :logger, level: :warning
