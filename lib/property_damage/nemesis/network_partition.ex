defmodule PropertyDamage.Nemesis.NetworkPartition do
  @moduledoc """
  Simulate network partitions between components.

  Creates a network partition that blocks traffic between services,
  useful for testing split-brain scenarios, failover behavior, and
  partition tolerance.

  ## Partition Types

  - `:full` - Complete bidirectional partition (no traffic in either direction)
  - `:upstream` - Block traffic from client to server
  - `:downstream` - Block traffic from server to client

  ## Configuration

  - `:partition_type` - Type of partition (default: `:full`)
  - `:duration_ms` - How long the partition lasts (default: 5000ms)
  - `:target` - Specific service/host to partition (default: `:all`)

  ## Usage with Toxiproxy

  Live injection needs Toxiproxy configured in the adapter context. Return it
  from your adapter's `setup/1` (DR-038):

      def setup(_config) do
        {:ok, %{toxiproxy: %{proxy_name: "database", api_url: "http://localhost:8474"}}}
      end

  A top-level `:toxiproxy` key on the context is also honored for direct
  `inject/2` calls.

  ## Example

      # In your model
      def commands do
        [
          {QueryDatabase, weight: 5},
          {PropertyDamage.Nemesis.NetworkPartition, weight: 1}
        ]
      end

  ## Testing Behavior

  During a partition, your system should:
  - Detect the failure (timeouts, connection refused)
  - Handle gracefully (retry, failover, queue)
  - Recover when partition heals
  """

  @behaviour PropertyDamage.Nemesis

  alias PropertyDamage.Nemesis.Toxiproxy

  defstruct partition_type: :full,
            duration_ms: 5000,
            target: :all,
            injected_at: nil

  @partition_types [:full, :upstream, :downstream]

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :network_partition)
  end

  @impl true
  def inject(%__MODULE__{} = command, context) do
    now = System.monotonic_time(:millisecond)
    command = %{command | injected_at: now}

    {result, simulated?} = Toxiproxy.inject_toxics(context, toxics(command))

    case result do
      :ok ->
        event = %{
          __struct__: NetworkPartitioned,
          partition_type: command.partition_type,
          target: command.target,
          injected_at: now,
          simulated: simulated?
        }

        {:ok, [event]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def restore(%__MODULE__{} = command, context) do
    now = System.monotonic_time(:millisecond)

    {result, simulated?} = Toxiproxy.restore_toxics(context, toxic_names(command))

    case result do
      :ok ->
        event = %{
          __struct__: NetworkPartitionHealed,
          partition_type: command.partition_type,
          target: command.target,
          restored_at: now,
          duration_ms: now - (command.injected_at || now),
          simulated: simulated?
        }

        {:ok, [event]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec new!(map(), map()) :: StreamData.t(struct())
  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(member_of(@partition_types), fn type ->
      bind(integer(1000..15_000), fn duration ->
        constant(%__MODULE__{
          partition_type: Map.get(overrides, :partition_type, type),
          duration_ms: Map.get(overrides, :duration_ms, duration),
          target: Map.get(overrides, :target, :all)
        })
      end)
    end)
  end

  @impl true
  def auto_restore?, do: true

  @impl true
  def duration_ms(%__MODULE__{duration_ms: d}), do: d

  # ============================================================================
  # Toxic spec (pure)
  # ============================================================================

  @doc """
  The Toxiproxy toxics this command injects, as pure JSON-encodable maps.

  A partition is modeled with `bandwidth` toxics at `rate: 0`:

    * `:full` — **two** toxics (`pd_partition_up` on the upstream + `pd_partition_down`
      on the downstream), so traffic is blocked in *both* directions. A single
      unqualified bandwidth toxic defaults to downstream only, which would leave
      requests flowing — hence the pair.
    * `:upstream` / `:downstream` — one `pd_partition` toxic with `"stream"` set.
  """
  @spec toxics(%__MODULE__{}) :: [Toxiproxy.toxic()]
  def toxics(%__MODULE__{partition_type: :full}) do
    [
      bandwidth_toxic("pd_partition_up", "upstream"),
      bandwidth_toxic("pd_partition_down", "downstream")
    ]
  end

  def toxics(%__MODULE__{partition_type: stream}) when stream in [:upstream, :downstream] do
    [bandwidth_toxic("pd_partition", Atom.to_string(stream))]
  end

  defp bandwidth_toxic(name, stream) do
    %{
      "name" => name,
      "type" => "bandwidth",
      "stream" => stream,
      "attributes" => %{"rate" => 0}
    }
  end

  defp toxic_names(command), do: Enum.map(toxics(command), & &1["name"])
end

# Event structs
defmodule NetworkPartitioned do
  @moduledoc false
  defstruct [:partition_type, :target, :injected_at, simulated: false]
end

defmodule NetworkPartitionHealed do
  @moduledoc false
  defstruct [:partition_type, :target, :restored_at, :duration_ms, simulated: false]
end
