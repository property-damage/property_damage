defmodule PropertyDamage.Adapter do
  @moduledoc """
  Behaviour for adapters that execute commands against the System Under Test.

  Adapters are the bridge between the test framework and the actual SUT.
  They translate command structs into real operations (HTTP calls, function
  calls, message sends, etc.) and return the resulting events.

  ## Lifecycle

  During each test run (including shrink attempts), the adapter lifecycle is:

  1. `setup/1` - Establish connections, create clients
  2. `execute/3` × N - Execute each command in the sequence
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

  ## Served vs servant arguments (DR-027)

  `execute/3` keeps the user's *served* data and the framework's *servant*
  plumbing in separate, explicit channels:

      def execute(command, user_context, %PropertyDamage.Runtime{} = runtime)

  - `user_context` is **exactly** what your `setup/1` returned. The framework
    merges nothing into it, so a `setup/1` that returns `%{inject: ...}` is never
    clobbered, and you can pattern-match your own keys with confidence.
  - `runtime` is a `%PropertyDamage.Runtime{}` handle carrying the per-command
    framework affordances (`inject`, `start_poller`, `stutter`). See
    `PropertyDamage.Runtime`.

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
        def execute(%CreateOrder{amount: amt}, %{client: client}, _runtime) do
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
        def teardown(_user_context), do: :ok
      end

  The target module should implement `execute/3` with the same signature; the
  `user_context` and `runtime` are forwarded unchanged.

  ## Stutter/Idempotency Testing

  When stutter testing is enabled, the framework may execute commands multiple
  times to verify idempotent behavior. During retry executions, `runtime.stutter`
  is populated (and is `nil` on the first execution). Prefer
  `PropertyDamage.Runtime.stuttering?/1` over matching the field directly:

      def execute(%CreateOrder{} = cmd, %{client: client}, runtime) do
        headers =
          if PropertyDamage.Runtime.stuttering?(runtime) do
            [{"Idempotency-Key", runtime.stutter.idempotency_key}]
          else
            []
          end

        HTTPClient.post(client, "/orders", body, headers)
      end

  The `runtime.stutter` map (when present) contains:

  | Key | Type | Description |
  |-----|------|-------------|
  | `:attempt` | integer | Current attempt number (2, 3, etc. for retries) |
  | `:is_retry` | boolean | Always `true` for retry executions |
  | `:idempotency_key` | string or nil | From `Command.idempotency_key/1` if implemented |

  The first execution (attempt 1) has `runtime.stutter == nil`, so the adapter
  behaves normally for the initial execution.

  ## Mid-Execution Event Injection

  For commands with `:async` semantics that poll for completion, you may want to
  emit events as they happen rather than batching all events at the end.
  `runtime.inject` is a 1-arity function for this purpose:

      def execute(%CreateAuthorization{} = cmd, %{client: client}, runtime) do
        # Step 1: Create the authorization (T=0)
        {:ok, %{body: %{"id" => id, "status" => "processing"}}} =
          Req.post(client, url: "/authorizations", json: payload)

        # Inject immediately - projections update NOW at T=0
        runtime.inject.(%AuthorizationCreated{authorization_id: id})

        # Step 2: Poll until settled (T=5000)
        case poll_until_settled(client, id) do
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
  """

  @typedoc """
  Context returned by `setup/1`.

  This is whatever your adapter needs for execution: HTTP clients, database
  connections, configuration, etc. It is handed back to `execute/3` (as the
  second argument) and to `teardown/1` **exactly as returned** - the framework
  merges no keys into it.

  ## Example

      # In setup/1:
      {:ok, %{client: http_client, base_url: "http://localhost:4000"}}

      # In execute/3, pattern match on these keys:
      def execute(%CreateOrder{} = cmd, %{client: client, base_url: url}, _runtime) do
        # ...
      end
  """
  @type user_context :: term()

  @doc """
  Called once per run to establish context.

  Use for creating HTTP clients, connecting to databases, starting processes.
  The returned `user_context()` is handed back unchanged to `execute/3` (second
  argument) and `teardown/1`; framework affordances travel separately on the
  `%PropertyDamage.Runtime{}` handle, not merged into this value.

  ## Returns

  - `{:ok, user_context}` - Setup succeeded, context passed to subsequent calls
  - `{:error, reason}` - Setup failed, run aborted
  """
  @callback setup(config :: map()) :: {:ok, user_context()} | {:error, term()}

  @doc """
  Called once per run after all commands have executed (or on failure).

  Use for closing connections, stopping processes, cleanup. Receives the
  `user_context()` from `setup/1` exactly as returned. This is best-effort: the
  framework logs a warning if `teardown/1` raises but does not fail the test.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown(user_context()) :: :ok

  @doc """
  Execute a command against the SUT and return resulting events.

  This is called once per command in the sequence. The command struct
  has already had its Placeholders resolved to concrete values.

  The second argument is your `user_context()` from `setup/1` (exactly as
  returned). The third argument is the `%PropertyDamage.Runtime{}` handle
  carrying framework affordances (`inject`, `start_poller`, `stutter`).

  ## Returns

  - `{:ok, events}` - Command succeeded, events to record
  - `{:error, reason}` - Command failed, execution stops

  For `:probe`/`:async` (settle) commands only, `execute/3` may also return:

  - `{:settled, events}` - The eventually-consistent condition is met; treated
    like `{:ok, events}` and stops the settle loop.
  - `{:retry, reason}` - Not settled yet. The framework re-invokes `execute/3`
    per the command's settle config until `{:settled, _}` or the timeout.

  The framework owns the retry loop: an adapter returns `{:retry, _}` to ask to
  be called again, it does not sleep/poll inside `execute/3`. Returning
  `{:retry, _}` from a `:sync` command is a contract violation and is reported
  as `{:retry_from_sync_command, _}`.
  """
  @callback execute(
              command :: struct(),
              user_context :: user_context(),
              runtime :: PropertyDamage.Runtime.t()
            ) ::
              {:ok, [event :: struct()]}
              | {:error, term()}
              | {:settled, [event :: struct()]}
              | {:retry, term()}

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

  The target module should implement `execute/3` with the same signature; the
  `user_context` and `runtime` are forwarded unchanged.
  """
  defmacro delegate_execution(opts) do
    commands = Keyword.fetch!(opts, :for)
    target = Keyword.fetch!(opts, :to)

    for command <- commands do
      quote do
        @impl true
        def execute(%unquote(command){} = cmd, user_context, runtime) do
          unquote(target).execute(cmd, user_context, runtime)
        end
      end
    end
  end
end
