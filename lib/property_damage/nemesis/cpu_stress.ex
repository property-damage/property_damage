defmodule PropertyDamage.Nemesis.CPUStress do
  @moduledoc """
  Create CPU stress in the BEAM VM.

  Spawns processes that consume CPU cycles, useful for testing behavior
  under high load, scheduler contention, and timeout handling.

  ## Configuration

  - `:intensity` - Load level from 1-10 (default: 5)
  - `:schedulers` - Number of schedulers to stress (default: all)
  - `:duration_ms` - How long to stress (default: 5000ms)

  ## Warning

  This operation spawns busy-loop processes. It will affect system
  responsiveness during the stress period.

  ## Example

      def commands do
        [
          {5, HandleRequest},
          {1, PropertyDamage.Nemesis.CPUStress}
        ]
      end

  ## Testing Behavior

  Under CPU stress, your system should:
  - Maintain responsiveness (or gracefully degrade)
  - Handle timeouts appropriately
  - Not lose data during high load
  """

  @behaviour PropertyDamage.Nemesis

  defstruct intensity: 5,
            schedulers: :all,
            duration_ms: 5000,
            injected_at: nil,
            stress_pids: []

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :cpu_stress)
  end

  @impl true
  def inject(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    scheduler_count =
      case command.schedulers do
        :all -> :erlang.system_info(:schedulers_online)
        n when is_integer(n) -> min(n, :erlang.system_info(:schedulers_online))
      end

    # Spawn stress processes (not linked to avoid killing caller)
    pids =
      for i <- 1..scheduler_count do
        spawn(fn -> stress_loop(command.intensity, i) end)
      end

    # Store PIDs for cleanup
    Process.put(:nemesis_cpu_pids, pids)

    event = %{
      __struct__: CPUStressInjected,
      intensity: command.intensity,
      schedulers: scheduler_count,
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Kill all stress processes
    case Process.get(:nemesis_cpu_pids) do
      pids when is_list(pids) ->
        Enum.each(pids, fn pid ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end)

      _ ->
        :ok
    end

    Process.delete(:nemesis_cpu_pids)

    event = %{
      __struct__: CPUStressReleased,
      intensity: command.intensity,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(integer(1..10), fn intensity ->
      bind(integer(1000..10000), fn duration ->
        constant(%__MODULE__{
          intensity: Map.get(overrides, :intensity, intensity),
          schedulers: Map.get(overrides, :schedulers, :all),
          duration_ms: Map.get(overrides, :duration_ms, duration)
        })
      end)
    end)
  end

  @impl true
  def auto_restore?, do: true

  @impl true
  def duration_ms(%__MODULE__{duration_ms: d}), do: d

  # ============================================================================
  # Stress Loop
  # ============================================================================

  defp stress_loop(intensity, scheduler_hint) do
    # Pin to a specific scheduler if possible
    :erlang.process_flag(:scheduler, scheduler_hint)

    # Busy loop with occasional yields based on intensity
    # Lower intensity = more yields = less stress
    yield_every = max(1, 11 - intensity) * 1000

    do_stress(0, yield_every)
  end

  defp do_stress(counter, yield_every) do
    if rem(counter, yield_every) == 0 do
      # Brief yield to prevent complete lockup
      Process.sleep(1)
    end

    # Busy work - compute something to prevent optimization
    _ = :erlang.phash2(counter)

    do_stress(counter + 1, yield_every)
  end
end

# Event structs
defmodule CPUStressInjected do
  @moduledoc "Event emitted when CPU stress is injected"
  defstruct [:intensity, :schedulers, :injected_at]
end

defmodule CPUStressReleased do
  @moduledoc "Event emitted when CPU stress is released"
  defstruct [:intensity, :restored_at, :duration_ms]
end
