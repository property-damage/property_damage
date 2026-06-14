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
  3. **Restoration**: The fault is removed (automatically or explicitly)

  ## Example: Network Partition

      defmodule MyTest.Nemesis.PartitionNetwork do
        @behaviour PropertyDamage.Nemesis

        defstruct [:partition_type, :duration_ms]

        @impl true
        def inject(%__MODULE__{partition_type: type, duration_ms: duration}, ctx) do
          :ok = Toxiproxy.partition(ctx.proxy, type)

          # Return events describing what happened
          {:ok, [%NetworkPartitioned{type: type, started_at: System.monotonic_time()}]}
        end

        @impl true
        def restore(%__MODULE__{partition_type: type}, ctx) do
          Toxiproxy.restore(ctx.proxy, type)
          {:ok, [%NetworkRestored{type: type, ended_at: System.monotonic_time()}]}
        end

        @impl true
        def precondition(_state), do: true
      end

  ## Events in Log

  Nemesis events are recorded with `source: :nemesis`:

      %PropertyDamage.EventLog.Entry{
        timestamp: 12345,
        command_index: 5,
        event: %NetworkPartitioned{type: :full, started_at: 12345},
        source: :nemesis,
        nemesis_module: MyTest.Nemesis.PartitionNetwork
      }

  ## Model Integration

  Nemesis commands can be included in the model's command weights:

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

  The host-effect nemeses (`CPUStress`, `MemoryPressure`, `ResourceExhaustion`,
  `ProcessKill`) always inject real effects in the BEAM. The cooperative ones
  (`ClockSkew`, `SlowIO`, `CertificateExpiry`) install real state but only
  change behavior if your adapter consults their public API
  (e.g. `ClockSkew.now/0`); they are real, not simulated, but require adapter
  cooperation to observe.

  Assertion projections can adjust invariants during active faults:

      def check(:latency_within_sla, state, ctx) do
        if Map.get(state.active_faults, :network_partition) do
          :ok  # Skip SLA check during partition
        else
          if state.last_latency_ms < 100, do: :ok, else: {:error, "SLA violation"}
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

  Called automatically when:
  - The fault's duration expires
  - A RestoreFault command is executed
  - Test sequence ends (cleanup)

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
  (Optional) Generate a nemesis command struct from current state.

  If implemented, returns a StreamData generator for producing command instances.
  If not implemented, the command must be instantiated directly.
  """
  @callback new!(state :: map(), overrides :: map()) :: StreamData.t(struct())

  @doc """
  (Optional) Returns whether this nemesis command auto-restores after a duration.

  If true, the framework will automatically call `restore/2` after the command's
  duration expires. If false, restoration must be triggered by an explicit
  RestoreFault command.

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
    if function_exported?(module, :auto_restore?, 0) do
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
      function_exported?(module, :duration_ms, 1) ->
        module.duration_ms(command)

      Map.has_key?(command, :duration_ms) ->
        command.duration_ms

      true ->
        nil
    end
  end
end
