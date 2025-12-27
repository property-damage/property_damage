defmodule PropertyDamage.Nemesis.ResourceExhaustion do
  @moduledoc """
  Exhaust system resources to test resilience.

  Consumes various system resources (file descriptors, ports, ETS tables,
  atoms) to test how the system behaves under resource pressure.

  ## Configuration

  - `:resource` - What to exhaust: `:file_descriptors`, `:ports`, `:ets_tables`, `:processes`
  - `:count` - How many resources to consume (default varies by type)
  - `:duration_ms` - How long to hold resources (default: 5000ms)

  ## Warning

  This operation actually exhausts system resources. Use with caution:
  - `:file_descriptors` - Opens files, may hit ulimit
  - `:ports` - Opens ports, consumes system resources
  - `:ets_tables` - Creates ETS tables, consumes memory
  - `:processes` - Spawns processes, may hit process limit

  ## Example

      def commands do
        [
          {5, OpenConnection},
          {1, PropertyDamage.Nemesis.ResourceExhaustion}
        ]
      end

  ## Testing Behavior

  Under resource exhaustion, your system should:
  - Handle resource allocation failures
  - Clean up resources appropriately
  - Degrade gracefully when limits are reached
  """

  @behaviour PropertyDamage.Nemesis

  defstruct resource: :file_descriptors,
            count: 100,
            duration_ms: 5000,
            injected_at: nil

  @resources [:file_descriptors, :ports, :ets_tables, :processes]

  # Process dictionary key for held resources
  @resource_key :nemesis_resources

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :resource_exhaustion)
  end

  @impl true
  def inject(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    {resources, actual_count} = exhaust_resources(command.resource, command.count)

    # Store resources for cleanup
    Process.put(@resource_key, {command.resource, resources})

    event = %{
      __struct__: ResourceExhausted,
      resource: command.resource,
      requested_count: command.count,
      actual_count: actual_count,
      injected_at: now
    }

    {:ok, [event]}
  end

  @impl true
  def restore(%__MODULE__{} = command, _context) do
    now = System.monotonic_time(:millisecond)

    # Release held resources
    case Process.get(@resource_key) do
      {resource_type, resources} ->
        release_resources(resource_type, resources)

      _ ->
        :ok
    end

    Process.delete(@resource_key)

    event = %{
      __struct__: ResourceReleased,
      resource: command.resource,
      restored_at: now,
      duration_ms: now - (command.injected_at || now)
    }

    {:ok, [event]}
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(member_of(@resources), fn resource ->
      default_count = default_count_for(resource)

      bind(integer(div(default_count, 2)..(default_count * 2)), fn count ->
        bind(integer(1000..10000), fn duration ->
          constant(%__MODULE__{
            resource: Map.get(overrides, :resource, resource),
            count: Map.get(overrides, :count, count),
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

  # ============================================================================
  # Resource Exhaustion
  # ============================================================================

  defp exhaust_resources(:file_descriptors, count) do
    # Create temporary files and hold them open
    dir = System.tmp_dir!()

    fds =
      for i <- 1..count do
        path = Path.join(dir, "nemesis_fd_#{:erlang.unique_integer()}_#{i}")

        case File.open(path, [:write]) do
          {:ok, fd} ->
            # Write something so the file exists
            IO.write(fd, "nemesis")
            {fd, path}

          {:error, _} ->
            nil
        end
      end
      |> Enum.filter(& &1)

    {fds, length(fds)}
  end

  defp exhaust_resources(:ports, count) do
    # Open ports (UDP sockets are lightweight)
    ports =
      for _ <- 1..count do
        case :gen_udp.open(0) do
          {:ok, socket} -> socket
          {:error, _} -> nil
        end
      end
      |> Enum.filter(& &1)

    {ports, length(ports)}
  end

  defp exhaust_resources(:ets_tables, count) do
    # Create ETS tables
    tables =
      for i <- 1..count do
        try do
          name = :"nemesis_ets_#{:erlang.unique_integer()}_#{i}"
          :ets.new(name, [:set, :public])
        rescue
          ArgumentError -> nil
        end
      end
      |> Enum.filter(& &1)

    {tables, length(tables)}
  end

  defp exhaust_resources(:processes, count) do
    # Spawn sleeping processes
    pids =
      for _ <- 1..count do
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)
      end

    {pids, length(pids)}
  end

  # ============================================================================
  # Resource Release
  # ============================================================================

  defp release_resources(:file_descriptors, fds) do
    for {fd, path} <- fds do
      File.close(fd)
      File.rm(path)
    end

    :ok
  end

  defp release_resources(:ports, ports) do
    for port <- ports do
      :gen_udp.close(port)
    end

    :ok
  end

  defp release_resources(:ets_tables, tables) do
    for table <- tables do
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp release_resources(:processes, pids) do
    for pid <- pids do
      if Process.alive?(pid) do
        send(pid, :stop)
      end
    end

    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp default_count_for(:file_descriptors), do: 100
  defp default_count_for(:ports), do: 50
  defp default_count_for(:ets_tables), do: 20
  defp default_count_for(:processes), do: 1000
end

# Event structs
defmodule ResourceExhausted do
  @moduledoc "Event emitted when resources are exhausted"
  defstruct [:resource, :requested_count, :actual_count, :injected_at]
end

defmodule ResourceReleased do
  @moduledoc "Event emitted when resources are released"
  defstruct [:resource, :restored_at, :duration_ms]
end
