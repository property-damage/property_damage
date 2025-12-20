defmodule PropertyDamage.Adapter do
  @moduledoc """
  Behaviour for adapters that execute commands against the System Under Test.

  Adapters are the bridge between the test framework and the actual SUT.
  They translate command structs into real operations (HTTP calls, function
  calls, message sends, etc.) and return the resulting events.

  ## Lifecycle

  During each test run (including shrink attempts), the adapter lifecycle is:

  1. `setup/1` - Establish connections, create clients
  2. `execute/2` × N - Execute each command in the sequence
  3. `teardown/1` - Cleanup connections

  The full lifecycle with model hooks:

      Property test run
      ├── Model.setup_once()           # Once at start
      │
      ├── Run 1
      │   ├── Model.setup_each()       # Reset SUT state
      │   ├── Adapter.setup()          # Establish connections
      │   ├── Adapter.execute() × N    # Execute each command
      │   └── Adapter.teardown()       # Cleanup connections
      │
      ├── Run 2 ... Run N              # Same as above
      │
      ├── [On failure] Shrinking
      │   ├── Shrink attempt 1
      │   │   ├── Model.setup_each()
      │   │   ├── Adapter.setup()
      │   │   ├── Adapter.execute() × M
      │   │   └── Adapter.teardown()
      │   └── ...
      │
      └── Model.teardown_once()        # Once at end

  ## Example

      defmodule MyTest.APIAdapter do
        use PropertyDamage.Adapter

        @impl true
        def setup(config) do
          {:ok, client} = HTTPClient.start(base_url: config[:api_url])
          {:ok, %{client: client}}
        end

        @impl true
        def teardown(%{client: client}) do
          HTTPClient.stop(client)
          :ok
        end

        @impl true
        def execute(%CreateOrder{amount: amt}, %{client: client}) do
          case HTTPClient.post(client, "/orders", %{amount: amt}) do
            {:ok, %{status: 201, body: body}} ->
              {:ok, [%OrderCreated{order_id: body["id"], amount: amt}]}
            {:ok, %{status: 400}} ->
              {:ok, [%OrderRejected{reason: :invalid}]}
            {:error, reason} ->
              {:error, reason}
          end
        end
      end

  ## Delegation

  For complex adapters, use `delegate_execution/1` to route commands to
  sub-adapter modules:

      defmodule MyTest.MainAdapter do
        use PropertyDamage.Adapter

        delegate_execution for: [CreateOrder, ViewOrder], to: OrdersSubAdapter
        delegate_execution for: [CreatePayment], to: PaymentsSubAdapter

        @impl true
        def setup(config), do: {:ok, config}

        @impl true
        def teardown(_context), do: :ok
      end
  """

  @doc """
  Called once per run to establish context.

  Use for creating HTTP clients, connecting to databases, starting processes.
  The returned context is passed to `execute/2` and `teardown/1`.

  ## Returns

  - `{:ok, context}` - Setup succeeded, context passed to subsequent calls
  - `{:error, reason}` - Setup failed, run aborted
  """
  @callback setup(config :: map()) :: {:ok, context :: map()} | {:error, term()}

  @doc """
  Called once per run after all commands have executed (or on failure).

  Use for closing connections, stopping processes, cleanup.
  This is best-effort - the framework logs warnings if teardown raises
  but does not fail the test.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown(context :: map()) :: :ok

  @doc """
  Execute a command against the SUT and return resulting events.

  This is called once per command in the sequence. The command struct
  has already had its Refs resolved to concrete values.

  ## Returns

  - `{:ok, events}` - Command succeeded, events to record
  - `{:error, reason}` - Command failed, execution stops
  """
  @callback execute(command :: struct(), context :: map()) ::
              {:ok, [event :: struct()]} | {:error, term()}

  @doc """
  Optional callback for commands that need to register injector handlers.

  Some commands may need to set up listeners for async responses before
  execution. This callback allows registering handlers that will receive
  events from injector adapters.
  """
  @callback register_handler(command :: struct(), context :: map()) ::
              {:ok, handler_ref :: term()} | {:error, term()}

  @optional_callbacks [register_handler: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Adapter
      import PropertyDamage.Adapter, only: [delegate_execution: 1]
    end
  end

  @doc """
  Delegates command execution to a sub-adapter module.

  Useful for organizing complex adapters by domain or resource.

  ## Options

  - `:for` - List of command modules to delegate
  - `:to` - Module that handles these commands

  ## Example

      delegate_execution for: [CreateOrder, ViewOrder], to: OrdersSubAdapter
      delegate_execution for: [CreatePayment], to: PaymentsSubAdapter

  The target module should implement `execute/2` with the same signature.
  """
  defmacro delegate_execution(opts) do
    commands = Keyword.fetch!(opts, :for)
    target = Keyword.fetch!(opts, :to)

    for command <- commands do
      quote do
        def execute(%unquote(command){} = cmd, ctx) do
          unquote(target).execute(cmd, ctx)
        end
      end
    end
  end
end
