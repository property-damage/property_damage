defmodule PropertyDamage.MockServiceAdapter do
  @moduledoc """
  Behaviour for mock services that simulate third-party APIs.

  MockServiceAdapters intercept calls from the SUT to external services
  and return controlled responses. They can also inject events into the
  test framework based on those interactions.

  ## The Problem

  When testing a system that depends on external services (payment gateways,
  email providers, etc.), you need to control what those services return.
  MockServiceAdapter provides this capability:

  ```
  ┌─────────┐       ┌─────────┐       ┌───────────────────┐
  │  Test   │──────▶│   SUT   │──────▶│ MockServiceAdapter│
  │Framework│◀──────│         │◀──────│  (controlled)     │
  └─────────┘       └─────────┘       └───────────────────┘
       │                                      │
       │◀─────────── injected events ─────────┘
  ```

  ## Key Concepts

  ### Stateful Mock Behavior

  Mocks maintain state that evolves with the test. Commands can configure
  mock behavior, and the mock can react to events:

      defmodule PaymentGatewayMock do
        use PropertyDamage.MockServiceAdapter

        @impl true
        def init_state, do: %{behavior: :success}

        @impl true
        def on_command(%ConfigurePayment{behavior: b}, state) do
          %{state | behavior: b}
        end

        @impl true
        def handle_request(%{path: "/charge"}, state) do
          case state.behavior do
            :success -> {:ok, %{status: 200, body: %{id: "txn_123"}}}
            :decline -> {:ok, %{status: 402, body: %{error: "declined"}}}
          end
        end
      end

  ### Event Injection

  When the SUT calls the mock, you can inject events into the test:

      def handle_request(%{path: "/charge", body: body}, state) do
        response = %{status: 200, body: %{transaction_id: "txn_123"}}

        # These events are applied to projections
        events = [%PaymentProcessed{amount: body["amount"]}]

        {:ok, response, events}
      end

  ### Projection Awareness

  Mock handlers receive projection state, enabling realistic responses:

      def handle_request(%{path: "/balance"}, state) do
        balance = get_in(state.projections, [ModelState, :accounts, id, :balance])
        {:ok, %{status: 200, body: %{balance: balance}}}
      end

  ## Example

      defmodule MyTest.PaymentMock do
        use PropertyDamage.MockServiceAdapter

        @emits [PaymentAuthorized, PaymentDeclined]

        @impl true
        def setup(config) do
          {:ok, pid} = MockServer.start_link(port: 4445, handler: __MODULE__)
          {:ok, %{server: pid}}
        end

        @impl true
        def teardown(%{server: pid}) do
          MockServer.stop(pid)
          :ok
        end

        @impl true
        def init_state do
          %{behavior: :success, decline_reason: nil}
        end

        @impl true
        def on_command(%ConfigurePayment{behavior: b, reason: r}, state) do
          %{state | behavior: b, decline_reason: r}
        end

        @impl true
        def on_command(_other, state), do: state

        @impl true
        def on_event(_event, state), do: state

        @impl true
        def handle_request(%{path: "/authorize", body: body}, state) do
          case state.behavior do
            :success ->
              resp = %{status: 200, body: %{auth_code: "AUTH123"}}
              events = [%PaymentAuthorized{amount: body["amount"]}]
              {:ok, resp, events}

            :decline ->
              resp = %{status: 402, body: %{error: state.decline_reason}}
              events = [%PaymentDeclined{reason: state.decline_reason}]
              {:ok, resp, events}
          end
        end

        @impl true
        def handle_request(_request, _state) do
          {:ok, %{status: 404, body: %{error: "not_found"}}}
        end
      end

  ## Configuration Commands

  Define commands that configure mock behavior. These commands are executed
  against the SUT like normal commands, but the `on_command/2` callback
  allows mock adapters to react and update their behavior:

      defmodule ConfigurePayment do
        @behaviour PropertyDamage.Command

        defstruct [:behavior, :reason]

        @impl true
        def precondition(_state), do: true

        @impl true
        def new!(state, overrides \\\\ %{}) do
          StreamData.fixed_map(%{
            behavior: StreamData.member_of([:success, :decline]),
            reason: StreamData.member_of([nil, "insufficient_funds"])
          })
          |> StreamData.map(&struct!(__MODULE__, &1))
        end
      end

  The mock adapter's `on_command/2` callback receives all commands, allowing
  it to react to configuration commands and update its internal state.

  ## Wiring a mock into a run

  Declare mocks with the `:mock_services` option of `PropertyDamage.run/1`:

      PropertyDamage.run(
        model: PaymentTestModel,
        adapter: PaymentAdapter,
        mock_services: [MyTest.PaymentMock]
        # or, with config: mock_services: [{MyTest.PaymentMock, %{port: 4445}}]
      )

  For each run the framework:

  1. starts a `PropertyDamage.MockServiceRegistry`,
  2. registers each mock (calling `init_state/0`) and calls its `setup/1` with
     the entry's config merged with `%{registry: pid, event_queue: pid}`,
  3. calls `on_command/2` on every command before it executes,
  4. after each command, flushes the events mocks pushed into the registry,
     folds them into projections (`source: :mock`), and calls `on_event/2`,
  5. calls `teardown/1` and stops the registry at the end.

  The registry pid also travels to the adapter on the `PropertyDamage.Runtime`
  handle as `runtime.mock_registry`. When the SUT makes an outbound call to the
  mocked service, whatever plays the transport drives `handle_request/2` through
  the registry and pushes the returned events back:

      # In the mock's HTTP listener (started in setup/1), or directly in the
      # adapter's execute/3 for an in-process SUT:
      {:ok, state} = MockServiceRegistry.get_handler_state(registry, MyTest.PaymentMock)
      {:ok, response, events} = MyTest.PaymentMock.handle_request(request, state)
      :ok = MockServiceRegistry.push_events(registry, MyTest.PaymentMock, events)

  The framework never calls `handle_request/2` itself: only the SUT (or its
  stand-in) knows when an outbound call happens, so the transport drives it while
  the framework owns the surrounding lifecycle.
  """

  @doc """
  Called once per run to start the mock service.

  The config includes:
  - `:event_queue` - PID of the EventQueue for pushing events
  - `:registry` - PID of the MockServiceRegistry
  - Any adapter-specific config

  ## Returns

  - `{:ok, context}` - Mock started successfully
  - `{:error, reason}` - Failed to start
  """
  @callback setup(config :: map()) :: {:ok, context :: map()} | {:error, term()}

  @doc """
  Called once per run to stop the mock service.

  ## Returns

  Always returns `:ok`.
  """
  @callback teardown(context :: map()) :: :ok

  @doc """
  Initialize the mock's internal state.

  Called at the start of each test run. Return the initial state
  that will be passed to other callbacks.
  """
  @callback init_state() :: map()

  @doc """
  React to a command being executed.

  Called before each command is executed against the SUT. Use this to
  update mock behavior based on commands.

  ## Parameters

  - `command` - The command struct being executed
  - `state` - Current mock state

  ## Returns

  Updated mock state.
  """
  @callback on_command(command :: struct(), state :: map()) :: map()

  @doc """
  React to an event being produced.

  Called after events are produced (from SUT or mock injection). Use this
  to update mock state based on system events.

  ## Parameters

  - `event` - The event struct
  - `state` - Current mock state

  ## Returns

  Updated mock state.
  """
  @callback on_event(event :: struct(), state :: map()) :: map()

  @doc """
  Handle a request from the SUT.

  Called when the SUT makes a request to the mock service. Return a
  response and optionally events to inject.

  ## Parameters

  - `request` - The request from the SUT (format depends on protocol)
  - `state` - Current mock state including `:projections` key with projection states

  ## Returns

  - `{:ok, response}` - Return response, no events
  - `{:ok, response, events}` - Return response and inject events
  - `{:error, term()}` - Simulate an error (timeout, network failure, etc.)
  """
  @callback handle_request(request :: map(), state :: map()) ::
              {:ok, response :: map()}
              | {:ok, response :: map(), events :: [struct()]}
              | {:error, term()}

  @optional_callbacks [on_event: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.MockServiceAdapter
      Module.register_attribute(__MODULE__, :emits, accumulate: false)
      @before_compile PropertyDamage.MockServiceAdapter

      # Default implementations
      @impl true
      def on_event(_event, state), do: state

      defoverridable on_event: 2
    end
  end

  defmacro __before_compile__(env) do
    emits = Module.get_attribute(env.module, :emits) || []

    quote do
      @doc """
      Returns the list of event types this mock can emit.

      Used by the framework for validation and coverage checking.
      """
      @spec __emits__() :: [module()]
      def __emits__, do: unquote(emits)
    end
  end
end
