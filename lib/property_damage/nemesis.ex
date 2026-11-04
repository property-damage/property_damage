defmodule PropertyDamage.Nemesis do
  @moduledoc """
  Behaviour for fault injection commands.

  Nemesis commands represent faults that can be injected into the test environment
  to verify system resilience. Unlike regular commands that interact with the SUT,
  Nemesis commands modify the test environment itself (network conditions, proxies,
  resource limits, etc.).

  ## Why Nemesis Commands?

  Testing resilience requires injecting faults (network partitions, latency spikes,
  node crashes). These shouldn't "just happen" randomly - they should be:

  1. **Tracked in the event log** - For reproducibility and debugging
  2. **Shrinkable** - So we can find minimal fault scenarios
  3. **Composable** - Multiple faults can be active simultaneously
  4. **Time-bounded** - Faults should be restorable

  ## Lifecycle

  1. **Injection**: The Nemesis command is generated and executed
  2. **Active Period**: The fault is active for some duration
  3. **Restoration**: The framework removes the fault only if the nemesis's
     `auto_restore?/0` returns true. Otherwise the adapter or the test restores it.

  ## Example: Network Partition

      defmodule MyTest.Nemesis.PartitionNetwork do
        @behaviour PropertyDamage.Nemesis

        defstruct [:partition_type, :duration_ms]

        defmodule PartitionStarted do
          defstruct [:type, :started_at]
        end

        defmodule PartitionHealed do
          defstruct [:type, :ended_at]
        end

        @impl true
        def inject(%__MODULE__{partition_type: type}, ctx) do
          # The adapter's setup/1 return arrives under :adapter_context.
          # MyTest.Proxy stands for your own client of the fault tool.
          proxy = ctx.adapter_context.proxy
          :ok = MyTest.Proxy.partition(proxy, type)

          # Return events describing what happened
          {:ok, [%PartitionStarted{type: type, started_at: System.monotonic_time()}]}
        end

        @impl true
        def restore(%__MODULE__{partition_type: type}, ctx) do
          MyTest.Proxy.restore(ctx.adapter_context.proxy, type)
          {:ok, [%PartitionHealed{type: type, ended_at: System.monotonic_time()}]}
        end

        @impl true
        def precondition(_state), do: true

        # Required once the nemesis is listed in the model's commands/0: the
        # generator builds instances through new!/2, never through a command
        # generator.
        @impl true
        def new!(_state, overrides \\\\ %{}) do
          StreamData.bind(StreamData.member_of([:full, :asymmetric]), fn type ->
            StreamData.constant(%__MODULE__{
              partition_type: Map.get(overrides, :partition_type, type),
              duration_ms: Map.get(overrides, :duration_ms, 1_000)
            })
          end)
        end

        @impl true
        def duration_ms(%__MODULE__{duration_ms: duration}), do: duration
      end

  ## Events in Log

  Nemesis events are recorded with `source: :nemesis`:

      %PropertyDamage.EventLog.Entry{
        timestamp: 12345,
        command_index: 5,
        event: %MyTest.Nemesis.PartitionNetwork.PartitionStarted{type: :full, started_at: 12345},
        source: :nemesis,
        nemesis_module: MyTest.Nemesis.PartitionNetwork
      }

  ## Model Integration

  Nemesis commands can be included in the model's command weights. A nemesis
  listed here must implement `new!/2`, or validation fails with "missing
  required callback new!/2":

      @impl true
      def commands do
        [
          {CreateOrder, weight: 5},       # Normal commands
          {ViewOrder, weight: 3},
          {PartitionNetwork, weight: 1},  # Nemesis commands (lower weight)
          {InjectLatency, weight: 1}
        ]
      end

  ## Real vs simulated faults (no silent no-ops)

  Some nemeses can only inject a real fault when their backing mechanism is
  available. The network nemeses (`NetworkLatency`, `NetworkPartition`,
  `PacketLoss`) need Toxiproxy configured in the adapter context
  (`%{toxiproxy: %{proxy_name: ..., api_url: ...}}`); without it they cannot
  touch the network. Rather than silently no-op while reporting success (the
  former "chaos theater" behavior), they now tag their events with
  `simulated: true`, so a fault that did nothing can never be mistaken for one
  that did. Use `simulated_event?/1` to detect it, or assert against the
  `:simulated` field directly.

  > #### Scope: faults reach the SUT, not the test harness {: .info}
  >
  > The built-in nemeses fault the SUT's **network path** through Toxiproxy.
  > Earlier versions also shipped nemeses that stressed the *local* BEAM/host
  > (CPU, memory, OS resources), killed local processes, or installed a virtual
  > clock the adapter had to read. Those were removed: they only affected the
  > test harness's own VM, not an external System Under Test driven through an
  > adapter, so they tested the wrong thing (and the host-stress ones could
  > destabilize the run itself). A nemesis should inject a fault into the SUT's
  > environment; if you need to fault an in-process collaborator, do it in your
  > own adapter/command code.

  Check projections can adjust invariants during active faults. A projection
  tracks the fault from the nemesis events, and a `@check` function relaxes the
  check while the fault is active:

      defmodule MyTest.Projections.Latency do
        use PropertyDamage.Model.Projection

        alias MyTest.Events.Pong
        alias MyTest.Nemesis.PartitionNetwork.{PartitionHealed, PartitionStarted}

        @impl true
        def init, do: %{partitioned?: false, last_latency_ms: 0}

        @impl true
        def apply(state, %PartitionStarted{}), do: %{state | partitioned?: true}
        def apply(state, %PartitionHealed{}), do: %{state | partitioned?: false}
        def apply(state, %Pong{latency_ms: ms}), do: %{state | last_latency_ms: ms}
        def apply(state, _event), do: state

        # Skip the SLA check during a partition.
        @check every: Pong
        def latency_within_sla(state, _event) do
          state.partitioned? or state.last_latency_ms < 100
        end
      end
  """

  @doc """
  Precondition: Can this nemesis command be generated in the current state?

  Similar to regular command preconditions, but may check for things like:
  - No conflicting faults already active
  - Required infrastructure available
  - Test environment supports this fault type
  """
  @callback precondition(state :: map()) :: boolean()

  @doc """
  Inject the fault into the test environment.

  ## Parameters

  - `command` - The nemesis command struct containing fault parameters
  - `context` - Execution context with:
    - `:adapter_context` - From the adapter, may contain proxy info
    - `:event_queue` - For publishing events
    - `:active_faults` - Currently active faults

  ## Returns

  - `{:ok, events}` - Fault injected, returns events describing what happened
  - `{:error, reason}` - Fault injection failed
  """
  @callback inject(command :: struct(), context :: map()) ::
              {:ok, [struct()]} | {:error, term()}

  @doc """
  Restore normal operation after a fault.

  The framework calls it only for a fault whose nemesis returns true from
  `auto_restore?/0`, and only when:
  - The fault's duration has expired (checked after each command)
  - The test sequence ends (cleanup)

  A fault whose nemesis returns false from `auto_restore?/0` is never restored
  by the framework, not even at the end of the sequence. The adapter or the test
  must restore it.

  ## Parameters

  - `command` - The original nemesis command (to know what to restore)
  - `context` - Execution context

  ## Returns

  - `{:ok, events}` - Fault restored, returns events describing what happened
  - `{:error, reason}` - Restoration failed (this is problematic - may need manual cleanup)
  """
  @callback restore(command :: struct(), context :: map()) ::
              {:ok, [struct()]} | {:error, term()}

  @doc """
  Generate a nemesis command struct from current state.

  Returns a StreamData generator for producing command instances. The behaviour
  marks it optional, but a nemesis listed in the model's `commands/0` must
  implement it: validation rejects the model otherwise, and generation raises.
  Without it, a nemesis can only run from a pre-built command sequence.
  """
  @callback new!(state :: map(), overrides :: map()) :: StreamData.t(struct())

  @doc """
  (Optional) Returns whether this nemesis command auto-restores after a duration.

  If true, the framework calls `restore/2` once the command's duration has
  expired, or at the end of the sequence if the fault is still active. If
  false, the framework never calls `restore/2` for this command: the adapter or
  the test must restore the fault.

  Default: true (faults auto-restore)
  """
  @callback auto_restore?() :: boolean()

  @doc """
  (Optional) Returns the duration in milliseconds before auto-restoration.

  Only relevant if `auto_restore?/0` returns true.
  """
  @callback duration_ms(command :: struct()) :: non_neg_integer()

  @optional_callbacks [
    new!: 2,
    auto_restore?: 0,
    duration_ms: 1
  ]

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Check if a module implements the Nemesis behaviour.
  """
  @spec nemesis_module?(module()) :: boolean()
  def nemesis_module?(module) when is_atom(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    __MODULE__ in behaviours
  rescue
    _ -> false
  end

  @doc """
  Check if a command struct is a Nemesis command.
  """
  @spec nemesis_command?(term()) :: boolean()
  def nemesis_command?(%{__struct__: module}) do
    nemesis_module?(module)
  end

  def nemesis_command?(_), do: false

  @doc """
  Get whether a nemesis command auto-restores.
  """
  @spec auto_restores?(struct()) :: boolean()
  def auto_restores?(%{__struct__: module} = _command) do
    # Ensure the module is loaded before reflecting: function_exported?/3 returns
    # false for a not-yet-loaded module (first-touch reflection), which would
    # wrongly skip the callback.
    if Code.ensure_loaded?(module) and function_exported?(module, :auto_restore?, 0) do
      module.auto_restore?()
    else
      true
    end
  end

  @doc """
  Whether a nemesis event represents a *simulated* (no-op) fault.

  Some built-in network nemeses (`NetworkLatency`, `NetworkPartition`,
  `PacketLoss`) can only inject a real fault when Toxiproxy is configured in the
  adapter context. Without it they do nothing, but they used to report success
  as if the fault had landed ("chaos theater"). They now tag their events with
  `simulated: true` in that case, so a fault that did nothing can never
  masquerade as a real one. This helper reads that marker.

  Events that carry no `:simulated` field (every other nemesis, all of which
  inject real effects) are treated as not simulated.
  """
  @spec simulated_event?(struct() | map()) :: boolean()
  def simulated_event?(event) when is_map(event) do
    Map.get(event, :simulated, false) == true
  end

  @doc """
  Get the duration for a nemesis command.
  """
  @spec get_duration_ms(struct()) :: non_neg_integer() | nil
  def get_duration_ms(%{__struct__: module} = command) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :duration_ms, 1) ->
        module.duration_ms(command)

      Map.has_key?(command, :duration_ms) ->
        command.duration_ms

      true ->
        nil
    end
  end
end
