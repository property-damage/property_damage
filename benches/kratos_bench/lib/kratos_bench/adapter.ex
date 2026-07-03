defmodule KratosBench.Adapter do
  @moduledoc """
  Drives the model's intents against Ory Kratos, and owns the mock lifecycle.

  On `setup/1` it starts a `PropertyDamage.MockServiceRegistry`, registers
  `KratosBench.RegistrationMock`, seeds any bug flags into the mock's state, brings
  up the mock's web_hook listener, and resets Kratos (admin API) for per-sequence
  isolation. On each registration `execute/3` it notifies the registry of the
  command (so the mock picks its decision), submits the registration (Kratos calls
  the mock's web_hook synchronously, and the mock pushes its `RegistrationHandled`
  event into the registry), then flushes those injected events into the run. The
  query/login/delete commands read reality back from Kratos for the invariants.

  ## Config

    * `:public_url`, `:admin_url` — Kratos endpoints (required)
    * `:password` — the password every registration uses / login replays
    * `:mock_listen_port` — host port for the mock web_hook listener
    * `:reject_leaks`, `:modify_ignored` — seed mock misbehaviour (default false)
    * `:login_broken` — seed the adapter to log in with the wrong password
  """

  use PropertyDamage.Adapter

  alias KratosBench.Commands.{
    DeleteIdentity,
    ListIdentities,
    Login,
    RegisterAccept,
    RegisterModify,
    RegisterReject
  }

  alias KratosBench.Events.{IdentitiesListed, IdentityDeleted, LoginAttempted}
  alias KratosBench.{Kratos, RegistrationMock}
  alias PropertyDamage.MockServiceRegistry

  @impl true
  def setup(config) do
    client = Kratos.new(config)
    :ok = Kratos.ensure_ready(client)

    {:ok, registry} = MockServiceRegistry.start_link([])
    :ok = MockServiceRegistry.register(registry, RegistrationMock)
    :ok = seed_mock(registry, config)

    {:ok, _} =
      RegistrationMock.setup(%{
        registry: registry,
        mock_listen_port: Map.get(config, :mock_listen_port, 4500)
      })

    :ok = Kratos.reset!(client)

    {:ok,
     %{
       client: client,
       registry: registry,
       password: Map.fetch!(config, :password),
       login_broken: Map.get(config, :login_broken, false)
     }}
  end

  @impl true
  def teardown(%{registry: registry}) do
    RegistrationMock.teardown(%{})
    MockServiceRegistry.stop(registry)
    :ok
  end

  @impl true
  def execute(%RegisterAccept{} = cmd, ctx, _runtime), do: register(cmd, ctx)
  def execute(%RegisterReject{} = cmd, ctx, _runtime), do: register(cmd, ctx)
  def execute(%RegisterModify{} = cmd, ctx, _runtime), do: register(cmd, ctx)

  def execute(%ListIdentities{}, %{client: client}, _runtime) do
    {:ok, [%IdentitiesListed{identities: Kratos.list_identities(client)}]}
  end

  def execute(%Login{email: email, password: password}, ctx, _runtime) do
    used = if ctx.login_broken, do: "wrong-" <> password, else: password
    status = Kratos.login(ctx.client, email, used)
    outcome = if status == 200, do: :success, else: :failure
    {:ok, [%LoginAttempted{email: email, outcome: outcome}]}
  end

  def execute(%DeleteIdentity{email: email}, %{client: client}, _runtime) do
    :ok = Kratos.delete_identity(client, email)
    {:ok, [%IdentityDeleted{email: email}]}
  end

  # --- internals -------------------------------------------------------------

  # Notify the mock of the command (it picks accept/reject/modify), submit the
  # registration (which triggers the mock's web_hook synchronously), then flush
  # the events the mock injected into the registry.
  defp register(cmd, %{client: client, registry: registry, password: password}) do
    :ok = MockServiceRegistry.notify_command(registry, cmd)
    _ = Kratos.register(client, cmd.email, password)
    {:ok, MockServiceRegistry.flush_events(registry)}
  end

  defp seed_mock(registry, config) do
    {:ok, state} = MockServiceRegistry.get_state(registry, RegistrationMock)

    MockServiceRegistry.update_state(registry, RegistrationMock, %{
      state
      | reject_leaks: Map.get(config, :reject_leaks, false),
        modify_ignored: Map.get(config, :modify_ignored, false)
    })
  end
end
