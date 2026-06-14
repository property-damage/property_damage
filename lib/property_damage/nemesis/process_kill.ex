defmodule PropertyDamage.Nemesis.ProcessKill do
  @moduledoc """
  Kill or crash processes to test fault tolerance.

  Terminates processes by name or pattern, useful for testing supervision
  trees, process restart behavior, and system resilience.

  ## Configuration

  - `:target` - What to kill: `{:name, atom}`, `{:pattern, regex}`, or `{:random, count}`
  - `:signal` - Kill signal: `:kill`, `:shutdown`, `:normal`, or custom reason
  - `:restart_delay_ms` - Wait before allowing restart (default: 0)
  - `:duration_ms` - For random kills, how long to keep killing (default: 0, one-shot)

  ## Example

      def commands do
        [
          {ProcessData, weight: 5},
          {PropertyDamage.Nemesis.ProcessKill, weight: 1}
        ]
      end

  ## Targets

  - `{:name, :my_genserver}` - Kill a specific named process
  - `{:pattern, ~r/Worker/}` - Kill processes matching pattern
  - `{:random, 3}` - Kill 3 random processes from the group
  - `{:pid, pid}` - Kill a specific PID (for testing)

  ## Testing Behavior

  After process kills, your system should:
  - Restart via supervisors
  - Maintain consistency during restarts
  - Not lose critical state
  """

  @behaviour PropertyDamage.Nemesis

  defstruct target: {:random, 1},
            signal: :kill,
            restart_delay_ms: 0,
            duration_ms: 0,
            injected_at: nil,
            killed_pids: []

  @signals [:kill, :shutdown, :normal]

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(_state) do
    # Can always try to kill processes
    true
  end

  @impl true
  def inject(%__MODULE__{} = command, context) do
    now = System.monotonic_time(:millisecond)

    pids_to_kill = resolve_targets(command.target, context)

    killed =
      for pid <- pids_to_kill, Process.alive?(pid) do
        reason =
          case command.signal do
            :kill -> :kill
            :shutdown -> :shutdown
            :normal -> :normal
            custom -> custom
          end

        Process.exit(pid, reason)
        pid
      end

    # Optional delay before processes can restart
    if command.restart_delay_ms > 0 do
      Process.sleep(command.restart_delay_ms)
    end

    event = %{
      __struct__: ProcessKilled,
      target: command.target,
      signal: command.signal,
      killed_count: length(killed),
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # ProcessKill is typically one-shot, no restoration needed
    # But we emit an event for tracking

    event = %{
      __struct__: ProcessKillCompleted,
      target: command.target,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(member_of(@signals), fn signal ->
      bind(integer(0..1000), fn delay ->
        bind(integer(1..5), fn count ->
          constant(%__MODULE__{
            target: Map.get(overrides, :target, {:random, count}),
            signal: Map.get(overrides, :signal, signal),
            restart_delay_ms: Map.get(overrides, :restart_delay_ms, delay),
            duration_ms: 0
          })
        end)
      end)
    end)
  end

  @impl true
  def auto_restore?, do: false

  # ============================================================================
  # Target Resolution
  # ============================================================================

  defp resolve_targets({:name, name}, _context) do
    case Process.whereis(name) do
      nil -> []
      pid -> [pid]
    end
  end

  defp resolve_targets({:pid, pid}, _context) when is_pid(pid) do
    [pid]
  end

  defp resolve_targets({:pattern, pattern}, context) do
    # Get process pool from context or use registered processes
    pool = Map.get(context, :process_pool, get_registered_processes())

    pool
    |> Enum.filter(fn {name, _pid} ->
      Regex.match?(pattern, to_string(name))
    end)
    |> Enum.map(fn {_name, pid} -> pid end)
  end

  defp resolve_targets({:random, count}, context) do
    pool = Map.get(context, :process_pool, get_registered_processes())

    pool
    |> Enum.map(fn {_name, pid} -> pid end)
    |> Enum.filter(&Process.alive?/1)
    |> Enum.take_random(count)
  end

  defp resolve_targets({:supervised_by, supervisor}, _context) do
    case Process.whereis(supervisor) do
      nil ->
        []

      sup_pid ->
        Supervisor.which_children(sup_pid)
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
        |> Enum.filter(&is_pid/1)
    end
  end

  defp get_registered_processes do
    Process.registered()
    |> Enum.map(fn name -> {name, Process.whereis(name)} end)
    |> Enum.filter(fn {_name, pid} -> pid != nil end)
  end
end

# Event structs
defmodule ProcessKilled do
  @moduledoc "Event emitted when processes are killed"
  defstruct [:target, :signal, :killed_count, :injected_at]
end

defmodule ProcessKillCompleted do
  @moduledoc "Event emitted when process kill operation completes"
  defstruct [:target, :restored_at, :duration_ms]
end
