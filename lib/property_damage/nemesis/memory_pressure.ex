defmodule PropertyDamage.Nemesis.MemoryPressure do
  @moduledoc """
  Create memory pressure in the BEAM VM.

  Allocates memory to simulate low-memory conditions, useful for testing
  memory-sensitive code paths, garbage collection behavior, and OOM handling.

  ## Configuration

  - `:megabytes` - Amount of memory to allocate (default: 100MB)
  - `:duration_ms` - How long to hold the memory (default: 5000ms)
  - `:allocation_pattern` - How to allocate: `:bulk`, `:fragmented` (default: `:bulk`)

  ## Warning

  This operation actually allocates memory in the BEAM. Use with caution
  and ensure your test environment has sufficient resources.

  ## Example

      def commands do
        [
          {5, ProcessData},
          {1, PropertyDamage.Nemesis.MemoryPressure}
        ]
      end

  ## Testing Behavior

  Under memory pressure, your system should:
  - Handle allocation failures gracefully
  - Trigger appropriate cleanup/GC
  - Maintain functionality with reduced caching
  """

  @behaviour PropertyDamage.Nemesis

  defstruct megabytes: 100,
            duration_ms: 5000,
            allocation_pattern: :bulk,
            injected_at: nil,
            allocation_ref: nil

  @patterns [:bulk, :fragmented]

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :memory_pressure)
  end

  @impl true
  def inject(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Allocate memory based on pattern
    allocation =
      case command.allocation_pattern do
        :bulk ->
          # Single large binary
          :binary.copy(<<0>>, command.megabytes * 1024 * 1024)

        :fragmented ->
          # Many small allocations (more realistic pressure)
          chunk_size = 1024 * 1024
          chunks = command.megabytes

          for _ <- 1..chunks do
            :binary.copy(<<0>>, chunk_size)
          end
      end

    # Store allocation in process dictionary to prevent GC
    ref = make_ref()
    Process.put({:nemesis_memory, ref}, allocation)

    event = %{
      __struct__: MemoryPressureInjected,
      megabytes: command.megabytes,
      allocation_pattern: command.allocation_pattern,
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Remove all memory allocations from process dictionary
    Process.get_keys()
    |> Enum.filter(fn
      {:nemesis_memory, _} -> true
      _ -> false
    end)
    |> Enum.each(&Process.delete/1)

    # Force garbage collection
    :erlang.garbage_collect()

    event = %{
      __struct__: MemoryPressureReleased,
      megabytes: command.megabytes,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(integer(50..500), fn mb ->
      bind(member_of(@patterns), fn pattern ->
        bind(integer(1000..10000), fn duration ->
          constant(%__MODULE__{
            megabytes: Map.get(overrides, :megabytes, mb),
            allocation_pattern: Map.get(overrides, :allocation_pattern, pattern),
            duration_ms: Map.get(overrides, :duration_ms, duration)
          })
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
defmodule MemoryPressureInjected do
  @moduledoc "Event emitted when memory pressure is created"
  defstruct [:megabytes, :allocation_pattern, :injected_at]
end

defmodule MemoryPressureReleased do
  @moduledoc "Event emitted when memory pressure is released"
  defstruct [:megabytes, :restored_at, :duration_ms]
end
