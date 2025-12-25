defmodule PropertyDamage.EventLog.Entry do
  @moduledoc """
  Represents a single entry in the event log.

  The event log records all events that occur during test execution,
  wrapping each event with metadata for debugging and analysis.

  ## Event Sources

  Events can come from three sources:

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
  - `command_index` - Index of command that produced this event (nil for injected events)
  - `event` - The actual event struct
  - `source` - Either `:command`, `:injector`, or `:nemesis`
  - `injector_adapter` - Module that received the event (only for `:injector` source)
  - `nemesis_module` - Module that produced the event (only for `:nemesis` source)
  - `branch_id` - Branch identifier for parallel execution (nil for linear sequences)
  """
  @type t :: %__MODULE__{
          timestamp: integer(),
          command_index: non_neg_integer() | nil,
          event: struct(),
          source: :command | :injector | :nemesis,
          injector_adapter: module() | nil,
          nemesis_module: module() | nil,
          branch_id: non_neg_integer() | nil
        }

  defstruct [
    :timestamp,
    :command_index,
    :event,
    :source,
    :injector_adapter,
    :nemesis_module,
    :branch_id
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
end
