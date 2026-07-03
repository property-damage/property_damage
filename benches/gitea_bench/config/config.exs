import Config

api_port = System.get_env("PD_GITEA_API_PORT", "3101")
ui_port = System.get_env("PD_GITEA_UI_PORT", "3102")
webhook_port = System.get_env("PD_GITEA_WEBHOOK_PORT", "3103")

config :gitea_bench,
  api_url: System.get_env("PD_GITEA_API_URL", "http://localhost:#{api_port}"),
  ui_url: System.get_env("PD_GITEA_UI_URL", "http://localhost:#{ui_port}"),
  admin_user: System.get_env("PD_GITEA_ADMIN_USER", "pdadmin"),
  admin_password: System.get_env("PD_GITEA_ADMIN_PASSWORD", "Pd-Admin-12345"),
  # P9 webhook demo (dedicated gitea 1.24 instance). `webhook_url` is where the
  # bench drives the SUT and creates the system webhook; `webhook_listen_port` is
  # the host port the Bandit listener binds; `webhook_callback_host` is how the
  # container reaches that listener (host-gateway alias from docker-compose).
  webhook_url: System.get_env("PD_GITEA_WEBHOOK_URL", "http://localhost:#{webhook_port}"),
  webhook_listen_port: String.to_integer(System.get_env("PD_GITEA_WEBHOOK_LISTEN_PORT", "4040")),
  webhook_callback_host: System.get_env("PD_GITEA_WEBHOOK_CALLBACK_HOST", "host.docker.internal")
