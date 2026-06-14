import Config

# Connection endpoints. A PD_REDIS_URL wins (CI service container / BYO Redis);
# otherwise the dedicated docker-compose container on PD_REDIS_PORT.
#
# Toxiproxy (used by the fault-injection suites only) is addressed separately:
#   PD_TOXIPROXY_URL  - control API   (default http://localhost:8474)
#   PD_REDIS_PROXY_*  - the proxied Redis the app connects through under faults
config :redis_bench,
  redis_url: System.get_env("PD_REDIS_URL", "redis://localhost:6390"),
  toxiproxy_url: System.get_env("PD_TOXIPROXY_URL", "http://localhost:8474"),
  redis_proxy_host: System.get_env("PD_REDIS_PROXY_HOST", "localhost"),
  redis_proxy_port: String.to_integer(System.get_env("PD_REDIS_PROXY_PORT", "6391")),
  # Where Toxiproxy reaches Redis. Inside the compose network that is the
  # service name; with a BYO/CI setup override it via PD_REDIS_UPSTREAM.
  redis_upstream: System.get_env("PD_REDIS_UPSTREAM", "redis:6379")

config :logger, level: :warning
