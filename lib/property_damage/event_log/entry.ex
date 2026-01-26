defmodule PropertyDamage.EventLog.Entry do
  @moduledoc """
  Represents a single entry in the event log.

  The event log records all events that occur during test execution,
  wrapping each event with metadata for debugging and analysis.

  ## Event Sources

  Events can come from eight sources:

  1. **Command events** (`:command` source) - Events produced by executing
     commands against the SUT. These have a `command_index` indicating
     which command produced them.

  2. **Injector events** (`:injector` source) - Events received from the
     SUT via injector adapters (webhooks, callbacks, etc.). These have
     `command_index: nil` since they're not triggered by a specific command,
     and include the `injector_adapter` module that received them.

  3. **Nemesis events** (`:nemesis` source) - Events produced by fault
     injection commands. These have a `command_index` like command events,
     plus the `nemesis_module` that produced them.

  4. **Telemetry events** (`:telemetry` source) - Events derived from
     OpenTelemetry spans received from the SUT. These include the
     `telemetry_receiver` module and optional `trace_id`/`span_id`.

  5. **Stutter events** (`:stutter` source) - Events from retry executions
     during idempotency testing. These are captured but NOT applied to
     projections. They include `stutter_attempt` and `stutter_comparison`.

  6. **Mock events** (`:mock` source) - Events injected by mock service
     adapters when the SUT calls them. These have a `command_index` indicating
     which command triggered the mock call.

  7. **Injected events** (`:injected` source) - Events emitted mid-execution
     by adapters with `:async` semantics using `ctx.inject.(event)`. These
     update projections immediately when injected, unlike command events which
     batch all events at the end. They have a `command_index` indicating
     which command's adapter injected them.

  8. **Resource poller events** (`:resource_poller` source) - Events injected
     by background resource pollers started via `ctx.start_poller.(opts)`.
     These are processed between commands when the EventQueue is drained.
     They have a `command_index` indicating which command started the poller,
     and a `resource_poller_id` identifying the specific poller instance.

  ## Example Event Log

      [
        %Entry{timestamp: 1, command_index: 0, event: %OrderCreated{...}, source: :command},
        %Entry{timestamp: 15, command_index: nil, event: %PaymentConfirmed{...}, source: :injector, injector_adapter: PaymentWebhook},
        %Entry{timestamp: 20, command_index: 1, event: %OrderCancelled{...}, source: :command}
      ]

  ## Timestamp

  The timestamp is monotonic time in milliseconds (via `System.monotonic_time/1`),
  ensuring consistent ordering even if system clock changes.

  ## System Events

  System events (like `CommandSequenceTerminated`) are also recorded in the
  event log but are metadata-only - projections do not receive them. They
  exist for debugging and visualization purposes.
  """

  @typedoc """
  An event log entry.

  - `timestamp` - Monotonic time in milliseconds when event was recorded
  - `command_index` - Index of command that produced this event (nil for injected/telemetry events)
  - `event` - The actual event struct
  - `source` - One of `:command`, `:injector`, `:nemesis`, `:telemetry`, `:stutter`, `:mock`, `:injected`, or `:resource_poller`
  - `injector_adapter` - Module that received the event (only for `:injector` source)
  - `nemesis_module` - Module that produced the event (only for `:nemesis` source)
  - `telemetry_receiver` - Module that received the span (only for `:telemetry` source)
  - `trace_id` - Distributed trace ID (only for `:telemetry` source)
  - `span_id` - Span ID within the trace (only for `:telemetry` source)
  - `branch_id` - Branch identifier for parallel execution (nil for linear sequences)
  - `stutter_attempt` - Attempt number for stutter retries (only for `:stutter` source)
  - `stutter_comparison` - Comparison result with original events (only for `:stutter` source)
  - `resource_poller_id` - Reference identifying the poller instance (only for `:resource_poller` source)
  """
  @type t :: %__MODULE__{
          timestamp: integer(),
          command_index: non_neg_integer() | nil,
          event: struct(),
          source:
            :command
            | :injector
            | :nemesis
            | :telemetry
            | :stutter
            | :mock
            | :injected
            | :resource_poller,
          injector_adapter: module() | nil,
          nemesis_module: module() | nil,
          telemetry_receiver: module() | nil,
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          branch_id: non_neg_integer() | nil,
          stutter_attempt: pos_integer() | nil,
          stutter_comparison: :match | {:mismatch, map()} | nil,
          resource_poller_id: reference() | nil
        }

  defstruct [
    :timestamp,
    :command_index,
    :event,
    :source,
    :injector_adapter,
    :nemesis_module,
    :telemetry_receiver,
    :trace_id,
    :span_id,
    :branch_id,
    :stutter_attempt,
    :stutter_comparison,
    :resource_poller_id
  ]

  @doc """
  Create a new entry for a command event.

  ## Parameters

  - `event` - The event struct
  - `command_index` - Index of the command that produced this event

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_command(%SomeEvent{}, 0)
      iex> entry.source
      :command
      iex> entry.command_index
      0
  """
  @spec from_command(struct(), non_neg_integer(), keyword()) :: t()
  def from_command(event, command_index, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: command_index,
      event: event,
      source: :command,
      injector_adapter: nil
    }
  end

  @doc """
  Create a new entry for an injector event.

  ## Parameters

  - `event` - The event struct
  - `injector_adapter` - Module that received the event

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_injector(%PaymentEvent{}, PaymentWebhook)
      iex> entry.source
      :injector
      iex> entry.command_index
      nil
  """
  @spec from_injector(struct(), module(), keyword()) :: t()
  def from_injector(event, injector_adapter, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: nil,
      event: event,
      source: :injector,
      injector_adapter: injector_adapter
    }
  end

  @doc """
  Check if an entry is from a command.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_command(%SomeEvent{}, 0)
      iex> PropertyDamage.EventLog.Entry.command?(entry)
      true
  """
  @spec command?(t()) :: boolean()
  def command?(%__MODULE__{source: :command}), do: true
  def command?(%__MODULE__{}), do: false

  @doc """
  Check if an entry is from an injector.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_injector(%SomeEvent{}, SomeInjector)
      iex> PropertyDamage.EventLog.Entry.injector?(entry)
      true
  """
  @spec injector?(t()) :: boolean()
  def injector?(%__MODULE__{source: :injector}), do: true
  def injector?(%__MODULE__{}), do: false

  @doc """
  Create a new entry for a nemesis event.

  ## Parameters

  - `event` - The event struct
  - `command_index` - Index of the nemesis command that produced this event
  - `nemesis_module` - Module that produced the event

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)
  - `:branch_id` - Branch identifier for parallel execution

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_nemesis(%PartitionEvent{}, 3, MyNemesis)
      iex> entry.source
      :nemesis
      iex> entry.nemesis_module
      MyNemesis
  """
  @spec from_nemesis(struct(), non_neg_integer(), module(), keyword()) :: t()
  def from_nemesis(event, command_index, nemesis_module, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: command_index,
      event: event,
      source: :nemesis,
      injector_adapter: nil,
      nemesis_module: nemesis_module,
      branch_id: Keyword.get(opts, :branch_id)
    }
  end

  @doc """
  Check if an entry is from a nemesis.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_nemesis(%SomeEvent{}, 0, MyNemesis)
      iex> PropertyDamage.EventLog.Entry.nemesis?(entry)
      true
  """
  @spec nemesis?(t()) :: boolean()
  def nemesis?(%__MODULE__{source: :nemesis}), do: true
  def nemesis?(%__MODULE__{}), do: false

  @doc """
  Create a new entry for a telemetry event.

  ## Parameters

  - `event` - The event struct (derived from a telemetry span)
  - `telemetry_receiver` - Module that received and converted the span

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)
  - `:trace_id` - Distributed trace ID
  - `:span_id` - Span ID within the trace
  - `:branch_id` - Branch identifier for parallel execution

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_telemetry(%SlowQuery{}, MyReceiver, trace_id: "abc123")
      iex> entry.source
      :telemetry
      iex> entry.trace_id
      "abc123"
  """
  @spec from_telemetry(struct(), module(), keyword()) :: t()
  def from_telemetry(event, telemetry_receiver, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: nil,
      event: event,
      source: :telemetry,
      injector_adapter: nil,
      nemesis_module: nil,
      telemetry_receiver: telemetry_receiver,
      trace_id: Keyword.get(opts, :trace_id),
      span_id: Keyword.get(opts, :span_id),
      branch_id: Keyword.get(opts, :branch_id)
    }
  end

  @doc """
  Check if an entry is from telemetry.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_telemetry(%SomeEvent{}, MyReceiver)
      iex> PropertyDamage.EventLog.Entry.telemetry?(entry)
      true
  """
  @spec telemetry?(t()) :: boolean()
  def telemetry?(%__MODULE__{source: :telemetry}), do: true
  def telemetry?(%__MODULE__{}), do: false

  @doc """
  Create a new entry for a stutter (retry) event.

  Stutter events are captured during idempotency testing but NOT applied
  to projections. They record the result of retry executions for comparison.

  ## Parameters

  - `event` - The event struct from retry execution
  - `command_index` - Index of the command being retried
  - `attempt` - Attempt number (2, 3, etc. - first execution is attempt 1)
  - `comparison` - Result of comparing with original events

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)
  - `:branch_id` - Branch identifier for parallel execution

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_stutter(%OrderCreated{}, 5, 2, :match)
      iex> entry.source
      :stutter
      iex> entry.stutter_attempt
      2
  """
  @spec from_stutter(struct(), non_neg_integer(), pos_integer(), term(), keyword()) :: t()
  def from_stutter(event, command_index, attempt, comparison, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: command_index,
      event: event,
      source: :stutter,
      injector_adapter: nil,
      nemesis_module: nil,
      telemetry_receiver: nil,
      trace_id: nil,
      span_id: nil,
      branch_id: Keyword.get(opts, :branch_id),
      stutter_attempt: attempt,
      stutter_comparison: comparison
    }
  end

  @doc """
  Check if an entry is from stutter (retry) testing.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_stutter(%SomeEvent{}, 0, 2, :match)
      iex> PropertyDamage.EventLog.Entry.stutter?(entry)
      true
  """
  @spec stutter?(t()) :: boolean()
  def stutter?(%__MODULE__{source: :stutter}), do: true
  def stutter?(%__MODULE__{}), do: false

  @doc """
  Create a new entry for a mock-injected event.

  Mock events are injected by mock service adapters when the SUT calls them.
  They are applied to projections like command events.

  ## Parameters

  - `event` - The event struct injected by the mock
  - `command_index` - Index of the command that triggered the mock call

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)
  - `:branch_id` - Branch identifier for parallel execution

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_mock(%PaymentProcessed{}, 3)
      iex> entry.source
      :mock
      iex> entry.command_index
      3
  """
  @spec from_mock(struct(), non_neg_integer(), keyword()) :: t()
  def from_mock(event, command_index, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: command_index,
      event: event,
      source: :mock,
      injector_adapter: nil,
      nemesis_module: nil,
      telemetry_receiver: nil,
      trace_id: nil,
      span_id: nil,
      branch_id: Keyword.get(opts, :branch_id),
      stutter_attempt: nil,
      stutter_comparison: nil
    }
  end

  @doc """
  Check if an entry is from a mock service adapter.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_mock(%SomeEvent{}, 0)
      iex> PropertyDamage.EventLog.Entry.mock?(entry)
      true
  """
  @spec mock?(t()) :: boolean()
  def mock?(%__MODULE__{source: :mock}), do: true
  def mock?(%__MODULE__{}), do: false

  @doc """
  Create a new entry for an injected event.

  Injected events are emitted mid-execution by adapters using `ctx.inject.(event)`.
  Unlike command events which are batched at the end of execution, injected events
  update projections immediately when they're emitted. This is useful for adapters
  with `:async` semantics that need to emit events as they happen (e.g., emit
  `AuthorizationCreated` immediately when the resource is created, rather than
  waiting until polling completes).

  ## Parameters

  - `event` - The event struct
  - `command_index` - Index of the command whose adapter is injecting the event

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)
  - `:branch_id` - Branch identifier for parallel execution

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_injected(%AuthCreated{}, 3)
      iex> entry.source
      :injected
      iex> entry.command_index
      3
  """
  @spec from_injected(struct(), non_neg_integer(), keyword()) :: t()
  def from_injected(event, command_index, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: command_index,
      event: event,
      source: :injected,
      injector_adapter: nil,
      nemesis_module: nil,
      telemetry_receiver: nil,
      trace_id: nil,
      span_id: nil,
      branch_id: Keyword.get(opts, :branch_id),
      stutter_attempt: nil,
      stutter_comparison: nil
    }
  end

  @doc """
  Check if an entry was injected mid-execution by an adapter.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_injected(%SomeEvent{}, 0)
      iex> PropertyDamage.EventLog.Entry.injected?(entry)
      true
  """
  @spec injected?(t()) :: boolean()
  def injected?(%__MODULE__{source: :injected}), do: true
  def injected?(%__MODULE__{}), do: false

  @doc """
  Create a new entry for a resource poller event.

  Resource poller events are injected by background pollers started via
  `ctx.start_poller.(opts)`. They are processed between commands when
  the EventQueue is drained.

  ## Parameters

  - `event` - The event struct
  - `command_index` - Index of the command that started the poller
  - `poller_id` - Reference identifying the poller instance

  ## Options

  - `:timestamp` - Override timestamp (default: current monotonic time)
  - `:branch_id` - Branch identifier for parallel execution

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_resource_poller(%StatusChanged{}, 3, make_ref())
      iex> entry.source
      :resource_poller
      iex> entry.command_index
      3
  """
  @spec from_resource_poller(struct(), non_neg_integer(), reference(), keyword()) :: t()
  def from_resource_poller(event, command_index, poller_id, opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp, System.monotonic_time(:millisecond)),
      command_index: command_index,
      event: event,
      source: :resource_poller,
      injector_adapter: nil,
      nemesis_module: nil,
      telemetry_receiver: nil,
      trace_id: nil,
      span_id: nil,
      branch_id: Keyword.get(opts, :branch_id),
      stutter_attempt: nil,
      stutter_comparison: nil,
      resource_poller_id: poller_id
    }
  end

  @doc """
  Check if an entry was injected by a resource poller.

  ## Examples

      iex> entry = PropertyDamage.EventLog.Entry.from_resource_poller(%SomeEvent{}, 0, make_ref())
      iex> PropertyDamage.EventLog.Entry.resource_poller?(entry)
      true
  """
  @spec resource_poller?(t()) :: boolean()
  def resource_poller?(%__MODULE__{source: :resource_poller}), do: true
  def resource_poller?(%__MODULE__{}), do: false
end
