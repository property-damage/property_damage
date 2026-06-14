import Config

# Where the generated adapter (and the smoke tests) reach the SUT.
#
# When PD_OPENAPI_URL is set (CI service container / a BYO HTTP server) the
# bench points at that endpoint and does NOT start its own server. Otherwise
# the bench boots an in-process Bandit server on PD_OPENAPI_PORT and the URL is
# derived from it. Port 4010 is off the Phoenix default (4000) to avoid host
# collisions, matching the non-conventional-port convention of the other
# benches (oban=5434, redis=6390/6391/8474).
port = String.to_integer(System.get_env("PD_OPENAPI_PORT", "4010"))

config :openapi_bench,
  external_url: System.get_env("PD_OPENAPI_URL"),
  port: port,
  base_url: System.get_env("PD_OPENAPI_URL") || "http://localhost:#{port}"

config :logger, level: :warning
