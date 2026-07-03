import Config

public_port = System.get_env("PD_KRATOS_PUBLIC_PORT", "4433")
admin_port = System.get_env("PD_KRATOS_ADMIN_PORT", "4434")

config :kratos_bench,
  # Where the bench drives Kratos's public (self-service) and admin APIs.
  public_url: System.get_env("PD_KRATOS_PUBLIC_URL", "http://localhost:#{public_port}"),
  admin_url: System.get_env("PD_KRATOS_ADMIN_URL", "http://localhost:#{admin_port}"),
  # The password every registration uses; login replays it.
  password: System.get_env("PD_KRATOS_PASSWORD", "Str0ng-Pass-987x"),
  # The host port the bench's mock web_hook listener binds. Kratos reaches it via
  # the URL baked into config/kratos/kratos.yml (host.docker.internal:<port>); if
  # you change this port, update that URL too.
  mock_listen_port: String.to_integer(System.get_env("PD_KRATOS_MOCK_PORT", "4500"))
