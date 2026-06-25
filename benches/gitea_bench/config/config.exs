import Config

api_port = System.get_env("PD_GITEA_API_PORT", "3101")
ui_port = System.get_env("PD_GITEA_UI_PORT", "3102")

config :gitea_bench,
  api_url: System.get_env("PD_GITEA_API_URL", "http://localhost:#{api_port}"),
  ui_url: System.get_env("PD_GITEA_UI_URL", "http://localhost:#{ui_port}"),
  admin_user: System.get_env("PD_GITEA_ADMIN_USER", "pdadmin"),
  admin_password: System.get_env("PD_GITEA_ADMIN_PASSWORD", "Pd-Admin-12345")
