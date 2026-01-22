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

  ## Stutter/Idempotency Testing

  When stutter testing is enabled, the framework may execute commands multiple
  times to verify idempotent behavior. During retry executions, the adapter
  context includes a `:stutter` key with information the adapter can use:

      %{
        stutter: %{
          attempt: 2,           # Current attempt (2, 3, etc. for retries)
          is_retry: true,       # Always true for retry executions
          idempotency_key: "abc123"  # From Command.idempotency_key/1, or nil
        }
      }

  Adapters can use this to include idempotency keys in HTTP headers:

      def execute(%CreateOrder{} = cmd, context) do
        headers = build_headers(context)
        # headers will include "Idempotency-Key" if stutter context present
        HTTPClient.post(context.client, "/orders", body, headers)
      end

      defp build_headers(%{stutter: %{idempotency_key: key}}) when is_binary(key) do
        [{"Idempotency-Key", key}]
      end
      defp build_headers(_context), do: []

  The first execution (attempt 1) does NOT include stutter context, only retries do.
  This allows the adapter to behave normally for the initial execution.

  ## Mid-Execution Event Injection

  For commands with `:async` semantics that poll for completion, you may want to
  emit events as they happen rather than batching all events at the end. The
  adapter context includes an `:inject` function for this purpose:

      %{
        inject: #Function<...>  # Call with event to inject it immediately
      }

  Use this to emit events at the correct time in the execution timeline:

      def execute(%CreateAuthorization{} = cmd, ctx) do
        # Step 1: Create the authorization (T=0)
        {:ok, %{body: %{"id" => id, "status" => "processing"}}} =
          Req.post(ctx.client, url: "/authorizations", json: payload)

        # Inject immediately - projections update NOW at T=0
        ctx.inject.(%AuthorizationCreated{authorization_id: id})

        # Step 2: Poll until settled (T=5000)
        case poll_until_settled(ctx.client, id) do
          :approved ->
            # Return settlement event - recorded at T=5000
            {:ok, [%AuthorizationApproved{authorization_id: id}]}

          :declined ->
            {:ok, [%AuthorizationDeclined{authorization_id: id}]}
        end
      end

  Key behaviors:
  - Injected events update projections immediately
  - Injected events are recorded in the event log with source `:injected`
  - For events with `external()` fields, values are captured from the first injected event
  - Adapters that don't use `inject` continue to work unchanged

  This is particularly useful when your model needs to track intermediate states,
  or when assertions depend on events appearing at the correct point in time.

  ## Execute Context

  The context map passed to `execute/2` contains:

  | Key | Type | Description |
  |-----|------|-------------|
  | *(from setup)* | any | Whatever your `setup/1` returned (e.g., `:client`, `:conn`) |
  | `:inject` | function | Call with event to inject it immediately into projections |
  | `:stutter` | map | Present only during retry executions (stutter/idempotency testing) |

  The `:stutter` map (when present) contains:

  | Key | Type | Description |
  |-----|------|-------------|
  | `:attempt` | integer | Current attempt number (2, 3, etc. for retries) |
  | `:is_retry` | boolean | Always `true` for retry executions |
  | `:idempotency_key` | string or nil | From `Command.idempotency_key/1` if implemented |
  """

  @typedoc """
  Context returned by `setup/1`.

  This is a map containing whatever your adapter needs for execution:
  HTTP clients, database connections, configuration, etc.

  ## Example

      # In setup/1:
      {:ok, %{client: http_client, base_url: "http://localhost:4000"}}

      # In execute/2, pattern match on these keys:
      def execute(%CreateOrder{} = cmd, %{client: client, base_url: url}) do
        # ...
      end
  """
  @type user_context :: map()

  @typedoc """
  Stutter context for idempotency testing.

  Present in `context()` only during retry executions when stutter testing is enabled.
  """
  @type stutter_context :: %{
          attempt: pos_integer(),
          is_retry: boolean(),
          idempotency_key: String.t() | nil
        }

  @typedoc """
  Full context passed to `execute/2`, `teardown/1`, and `register_handler/2`.

  This map contains:
  - All keys from your `user_context()` returned by `setup/1`
  - `:inject` - Function to inject events mid-execution (always present)
  - `:stutter` - Stutter context (only present during retry executions)

  ## Example

      def execute(%CreateOrder{} = cmd, context) do
        # Access your setup context
        client = context.client

        # Inject events mid-execution (for async commands)
        context.inject.(%OrderCreated{id: id})

        # Check for stutter/retry context
        case context do
          %{stutter: %{idempotency_key: key}} when is_binary(key) ->
            # Include idempotency header
          _ ->
            # Normal execution
        end
      end
  """
  @type context :: %{
          :inject => (struct() -> :ok),
          optional(:stutter) => stutter_context(),
          optional(atom()) => any()
        }

  @doc """
  Called once per run to establish context.

  Use for creating HTTP clients, connecting to databases, starting processes.
  The returned `user_context()` is merged with framework-provided keys
  (`:inject`, `:stutter`) to form the full `context()` passed to `execute/2`.

  ## Returns

  - `{:ok, user_context}` - Setup succeeded, context passed to subsequent calls
  - `{:error, reason}` - Setup failed, run aborted
  """
  @callback setup(config :: map()) :: {:ok, user_context()} | {:error, term()}

  @doc """
  Called once per run after all commands have executed (or on failure).

  Use for closing connections, stopping processes, cleanup.
  This is best-effort - the framework logs warnings if teardown raises
  but does not fail the test.

  Note: The context passed here is the full `context()`, not just `user_context()`.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown(context()) :: :ok

  @doc """
  Execute a command against the SUT and return resulting events.

  This is called once per command in the sequence. The command struct
  has already had its Refs/Placeholders resolved to concrete values.

  The `context()` contains your `user_context()` from `setup/1` plus
  framework-provided keys like `:inject` and optionally `:stutter`.

  ## Returns

  - `{:ok, events}` - Command succeeded, events to record
  - `{:error, reason}` - Command failed, execution stops
  """
  @callback execute(command :: struct(), context()) ::
              {:ok, [event :: struct()]} | {:error, term()}

  @doc """
  Optional callback for commands that need to register injector handlers.

  Some commands may need to set up listeners for async responses before
  execution. This callback allows registering handlers that will receive
  events from injector adapters.
  """
  @callback register_handler(command :: struct(), context()) ::
              {:ok, handler_ref :: term()} | {:error, term()}

  @typedoc """
  Timeout value for command execution.

  - Integer values are interpreted as seconds (e.g., `30` = 30 seconds)
  - Use tuples for other units:
    - `{500, :milliseconds}` - 500ms
    - `{2, :seconds}` - 2 seconds
    - `{5, :minutes}` - 5 minutes
  """
  @type timeout_value :: pos_integer() | {pos_integer(), :milliseconds | :seconds | :minutes}

  @doc """
  Return the timeout for executing a command.

  This callback allows adapters to specify how long a command execution
  should be allowed to run before timing out. This is particularly useful
  for load testing where hung commands should not cause unbounded pool growth.

  Integer values are interpreted as seconds. Use tuples for other units:
  - `30` - 30 seconds
  - `{500, :milliseconds}` - 500ms
  - `{2, :minutes}` - 2 minutes

  Override for specific commands that need longer timeouts (e.g., polling operations).

  ## Examples

      # Default for most commands
      def timeout(_command), do: 30  # 30 seconds

      # Longer timeout for async commands that poll
      def timeout(%CreateAuthorization{}), do: 120  # 2 minutes

      # Short timeout for in-memory adapters
      def timeout(_command), do: {100, :milliseconds}
  """
  @callback timeout(command :: struct()) :: timeout_value()

  @optional_callbacks [register_handler: 2]

  @doc """
  Macro to define an adapter with default behaviors.

  ## Options

  - `:default_timeout` - Default timeout for command execution (default: 30 seconds).
    Can be an integer (seconds) or a tuple like `{500, :milliseconds}`.

  ## Example

      defmodule MyHTTPAdapter do
        use PropertyDamage.Adapter, default_timeout: 30  # 30 seconds

        # Override for slow polling command
        def timeout(%CreateAuthorization{}), do: 120
      end

      defmodule MyInMemoryAdapter do
        use PropertyDamage.Adapter, default_timeout: {100, :milliseconds}

        # Override for complex calculation
        def timeout(%ComplexCalculation{}), do: {500, :milliseconds}
      end
  """
  defmacro __using__(opts) do
    default_timeout = Keyword.get(opts, :default_timeout, 30)

    quote do
      @behaviour PropertyDamage.Adapter
      import PropertyDamage.Adapter, only: [delegate_execution: 1]

      @impl true
      def timeout(_command), do: unquote(default_timeout)

      defoverridable timeout: 1
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
        @impl true
        def execute(%unquote(command){} = cmd, ctx) do
          unquote(target).execute(cmd, ctx)
        end
      end
    end
  end
end
