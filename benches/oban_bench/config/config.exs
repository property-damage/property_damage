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

# Staging (scheduled/retryable -> available) is built into Oban's core in 2.23,
# so no Stager plugin is needed. No plugins are enabled (no Pruner), so
# completed jobs persist for the resource pollers to observe.
#
# The retry bench needs retryable jobs re-staged FAST and reliably on a single
# node. Two things matter:
#   * the core Stager only stages while a node holds leadership. `plugins: false`
#     is documented to disable plugins AND leadership: Oban's normalize_peer
#     forces `{Oban.Peers.Isolated, leader?: false}` whenever plugins is false,
#     so no node was ever leader and retryable jobs sat forever -- forced
#     retries never re-ran. (Setting `peer:` alongside `plugins: false` does not
#     help; the plugins-false branch overrides it.) Dropping `plugins: false`
#     lets the Isolated peer default to leader?: true, so staging runs.
#   * `stage_interval: 50` re-stages within the resource poller's budget; the
#     default 1s left the first retry pending too long.
# Both are benign for the non-retrying EC and uniqueness benches.
config :oban_bench, Oban,
  repo: ObanBench.Repo,
  queues: [bench: 10],
  peer: Oban.Peers.Isolated,
  stage_interval: 50

config :logger, level: :warning
