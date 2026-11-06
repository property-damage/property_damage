import Config

# Connection endpoints. A PD_REDIS_URL wins (CI service container / BYO Redis);
# otherwise the dedicated docker-compose container on PD_REDIS_PORT.
config :redis_bench, redis_url: System.get_env("PD_REDIS_URL", "redis://localhost:6390")

config :logger, level: :warning
