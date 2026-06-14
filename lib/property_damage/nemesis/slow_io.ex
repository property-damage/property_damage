defmodule PropertyDamage.Nemesis.SlowIO do
  @moduledoc """
  Simulate slow I/O operations.

  Intercepts I/O operations and adds artificial delay, useful for testing
  behavior under slow disk, database, or external service conditions.

  ## Configuration

  - `:delay_ms` - Delay to add to each I/O operation (default: 100ms)
  - `:jitter_ms` - Random jitter ± this value (default: 0)
  - `:target` - What to slow: `:all`, `:reads`, `:writes` (default: `:all`)
  - `:duration_ms` - How long the slowdown persists (default: 5000ms)

  ## Usage

  This nemesis sets a flag that your adapter should check:

      defmodule MyAdapter do
        def read_file(path) do
          # Check for slow I/O nemesis
          if PropertyDamage.Nemesis.SlowIO.should_delay?(:reads) do
            PropertyDamage.Nemesis.SlowIO.apply_delay()
          end

          File.read(path)
        end
      end

  ## Example

      def commands do
        [
          {ReadDocument, weight: 5},
          {WriteDocument, weight: 5},
          {PropertyDamage.Nemesis.SlowIO, weight: 1}
        ]
      end

  ## Testing Behavior

  With slow I/O, your system should:
  - Handle timeouts appropriately
  - Not block user-facing operations
  - Maintain consistency despite delays
  """

  @behaviour PropertyDamage.Nemesis

  defstruct delay_ms: 100,
            jitter_ms: 0,
            target: :all,
            duration_ms: 5000,
            injected_at: nil

  @targets [:all, :reads, :writes]

  # Process dictionary key for IO delay config
  @io_key :nemesis_slow_io

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check if I/O delay should be applied for the given operation type.
  """
  @spec should_delay?(atom()) :: boolean()
  def should_delay?(operation_type \\ :all) do
    case Process.get(@io_key) do
      nil ->
        false

      %{target: :all} ->
        true

      %{target: target} ->
        operation_type == :all or operation_type == target
    end
  end

  @doc """
  Apply the configured I/O delay. Call this in your adapter when performing I/O.
  """
  @spec apply_delay() :: :ok
  def apply_delay do
    case Process.get(@io_key) do
      nil ->
        :ok

      %{delay_ms: delay, jitter_ms: jitter} ->
        actual_delay =
          if jitter > 0 do
            delay + :rand.uniform(jitter * 2) - jitter
          else
            delay
          end

        Process.sleep(max(0, actual_delay))
        :ok
    end
  end

  @doc """
  Get the current I/O delay configuration, if any.
  """
  @spec current_config() :: map() | nil
  def current_config do
    Process.get(@io_key)
  end

  @doc """
  Check if slow I/O is currently active.
  """
  @spec active?() :: boolean()
  def active? do
    Process.get(@io_key) != nil
  end

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :slow_io)
  end

  @impl true
  def inject(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Set up slow I/O configuration
    io_config = %{
      delay_ms: command.delay_ms,
      jitter_ms: command.jitter_ms,
      target: command.target
    }

    Process.put(@io_key, io_config)

    event = %{
      __struct__: SlowIOInjected,
      delay_ms: command.delay_ms,
      jitter_ms: command.jitter_ms,
      target: command.target,
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Remove slow I/O configuration
    Process.delete(@io_key)

    event = %{
      __struct__: SlowIORestored,
      delay_ms: command.delay_ms,
      target: command.target,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(integer(50..500), fn delay ->
      bind(integer(0..100), fn jitter ->
        bind(member_of(@targets), fn target ->
          bind(integer(1000..10_000), fn duration ->
            constant(%__MODULE__{
              delay_ms: Map.get(overrides, :delay_ms, delay),
              jitter_ms: Map.get(overrides, :jitter_ms, jitter),
              target: Map.get(overrides, :target, target),
              duration_ms: Map.get(overrides, :duration_ms, duration)
            })
          end)
        end)
      end)
    end)
  end

  @impl true
  def auto_restore?, do: true

  @impl true
  def duration_ms(%__MODULE__{duration_ms: d}), do: d
end

# Event structs
defmodule SlowIOInjected do
  @moduledoc "Event emitted when slow I/O is injected"
  defstruct [:delay_ms, :jitter_ms, :target, :injected_at]
end

defmodule SlowIORestored do
  @moduledoc "Event emitted when slow I/O is restored"
  defstruct [:delay_ms, :target, :restored_at, :duration_ms]
end
