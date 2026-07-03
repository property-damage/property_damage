defmodule KratosBench.RegistrationMock do
  @moduledoc """
  The `PropertyDamage.MockServiceAdapter` that answers Kratos's registration
  web_hook.

  Behaviour callbacks:

    * `init_state/0` — default decision `:accept`, seeded-bug flags off.
    * `on_command/2` — reads the executing command and sets the decision the next
      web_hook call will use (`RegisterAccept` → `:accept`, etc).
    * `handle_request/2` — pure: given the request and the current state, returns
      `{:ok, response, events}`. The HTTP response steers Kratos (a 4xx aborts the
      flow pre-persistence; a 2xx body can rewrite traits); the injected
      `RegistrationHandled` records what the mock decided (the model's expectation).
    * `setup/1` / `teardown/1` — own the host HTTP listener Kratos calls.

  ## How the mock reaches a run

  `PropertyDamage.run/1` can own the registry lifecycle via its `:mock_services`
  option (see README, "Wiring note"); this bench predates that option and has
  `KratosBench.Adapter` own the registry lifecycle using the registry's documented
  public API. This listener is the transport glue: on each inbound web_hook it
  reads the mock's state from the registry (`get_handler_state/2`), calls
  `handle_request/2`, and pushes the returned events back (`push_events/3`) for the
  adapter to flush into the run.

  A single Bandit listener is started once and kept up across sequences (the run
  process owns it); each sequence points `Hub` at its own registry, so a request
  always reaches the current sequence's mock.
  """

  use PropertyDamage.MockServiceAdapter

  alias __MODULE__.Hub
  alias KratosBench.Events.RegistrationHandled
  alias PropertyDamage.MockServiceRegistry

  @emits [RegistrationHandled]

  # --- MockServiceAdapter behaviour -----------------------------------------

  @impl true
  def init_state do
    %{decision: :accept, reject_leaks: false, modify_ignored: false}
  end

  @impl true
  def on_command(%KratosBench.Commands.RegisterAccept{}, state),
    do: %{state | decision: :accept}

  def on_command(%KratosBench.Commands.RegisterReject{}, state),
    do: %{state | decision: :reject}

  def on_command(%KratosBench.Commands.RegisterModify{}, state),
    do: %{state | decision: :modify}

  def on_command(_command, state), do: state

  @impl true
  def handle_request(%{body: body}, state) do
    email = body["email"]
    role = KratosBench.mock_role()

    case state.decision do
      :accept ->
        {:ok, ok_response(%{}),
         [%RegistrationHandled{email: email, decision: :accept, role: nil}]}

      :reject ->
        # Seeded bug `reject_leaks`: the mock lies and returns 2xx, so Kratos
        # persists an identity the model still expects not to exist.
        resp = if state.reject_leaks, do: ok_response(%{}), else: reject_response()
        {:ok, resp, [%RegistrationHandled{email: email, decision: :reject, role: nil}]}

      :modify ->
        # Seeded bug `modify_ignored`: the mock returns 2xx without the trait
        # rewrite, so the identity persists without the role the model expects.
        resp = if state.modify_ignored, do: ok_response(%{}), else: modify_response(email, role)
        {:ok, resp, [%RegistrationHandled{email: email, decision: :modify, role: role}]}
    end
  end

  @impl true
  def setup(%{registry: registry} = config) do
    Hub.ensure_started()
    ensure_listener(Map.get(config, :mock_listen_port, 4500))
    Hub.put(registry: registry)
    {:ok, %{}}
  end

  @impl true
  def teardown(_context) do
    # Drop the current registry so a stray/late web_hook between sequences is
    # ignored; the listener stays up for the next sequence.
    if Process.whereis(Hub), do: Hub.put(registry: nil)
    :ok
  end

  # --- responses -------------------------------------------------------------

  defp ok_response(body), do: %{status: 200, body: body}

  defp reject_response do
    %{
      status: 400,
      body: %{
        messages: [
          %{
            instance_ptr: "#/traits/email",
            messages: [%{id: 123, text: "rejected by mock", type: "error"}]
          }
        ]
      }
    }
  end

  defp modify_response(email, role) do
    %{
      status: 200,
      body: %{
        identity: %{
          traits: %{email: email, role: role},
          metadata_public: %{source: "mock"}
        }
      }
    }
  end

  # --- listener lifecycle ----------------------------------------------------

  defp ensure_listener(port) do
    case Hub.get() do
      %{listener: pid} when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: start_listener(port)

      _ ->
        start_listener(port)
    end
  end

  defp start_listener(port) do
    {:ok, pid} =
      Bandit.start_link(plug: __MODULE__.Router, scheme: :http, ip: {0, 0, 0, 0}, port: port)

    Hub.put(listener: pid)
    :ok
  end

  @doc false
  # Called by the Plug for each inbound web_hook. Reads the mock's state from the
  # current sequence's registry, runs handle_request/2, pushes the injected events
  # back, and returns the HTTP response Kratos will act on.
  def deliver(payload) do
    case Hub.get() do
      %{registry: registry} when is_pid(registry) ->
        {:ok, state} = MockServiceRegistry.get_handler_state(registry, __MODULE__)
        {:ok, response, events} = handle_request(%{path: "/registration", body: payload}, state)
        MockServiceRegistry.push_events(registry, __MODULE__, events)
        response

      _ ->
        ok_response(%{})
    end
  end

  defmodule Hub do
    @moduledoc false
    # Holds the current sequence's registry pid and the shared listener pid. Owned
    # by the run/test process (linked), so it survives across sequences.
    use Agent

    def ensure_started do
      case Process.whereis(__MODULE__) do
        nil -> Agent.start_link(fn -> %{registry: nil, listener: nil} end, name: __MODULE__)
        pid -> {:ok, pid}
      end
    end

    def put(fields), do: Agent.update(__MODULE__, &Map.merge(&1, Map.new(fields)))
    def get, do: Agent.get(__MODULE__, & &1)
  end

  defmodule Router do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/registration" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      response = KratosBench.RegistrationMock.deliver(payload)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(response.status, Jason.encode!(response.body))
    end

    match _ do
      send_resp(conn, 200, "{}")
    end
  end
end
