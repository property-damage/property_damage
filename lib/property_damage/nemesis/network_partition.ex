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
  - `:asymmetric` - Requests go through, responses blocked

  ## Configuration

  - `:partition_type` - Type of partition (default: `:full`)
  - `:duration_ms` - How long the partition lasts (default: 5000ms)
  - `:target` - Specific service/host to partition (default: `:all`)

  ## Usage with Toxiproxy

      context = %{toxiproxy: %{proxy_name: "database", api_url: "http://localhost:8474"}}

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

  defstruct partition_type: :full,
            duration_ms: 5000,
            target: :all,
            injected_at: nil

  @partition_types [:full, :upstream, :downstream, :asymmetric]

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

    {result, simulated?} =
      case get_toxiproxy(context) do
        {:ok, proxy_config} ->
          {inject_toxiproxy(command, proxy_config), false}

        :not_configured ->
          {inject_simulated(command, context), true}
      end

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

    {result, simulated?} =
      case get_toxiproxy(context) do
        {:ok, proxy_config} ->
          {restore_toxiproxy(command, proxy_config), false}

        :not_configured ->
          {restore_simulated(command, context), true}
      end

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
  # Toxiproxy Integration
  # ============================================================================

  defp get_toxiproxy(%{toxiproxy: config}) when is_map(config), do: {:ok, config}
  defp get_toxiproxy(_), do: :not_configured

  defp inject_toxiproxy(command, config) do
    proxy_name = config[:proxy_name] || "default"
    api_url = config[:api_url] || "http://localhost:8474"

    # For full partition, we use bandwidth toxic with rate=0
    # For directional, we'd need upstream/downstream specific toxics
    toxic =
      case command.partition_type do
        :full ->
          %{
            "name" => "pd_partition",
            "type" => "bandwidth",
            "attributes" => %{"rate" => 0}
          }

        :upstream ->
          %{
            "name" => "pd_partition",
            "type" => "bandwidth",
            "stream" => "upstream",
            "attributes" => %{"rate" => 0}
          }

        :downstream ->
          %{
            "name" => "pd_partition",
            "type" => "bandwidth",
            "stream" => "downstream",
            "attributes" => %{"rate" => 0}
          }

        :asymmetric ->
          # Requests go through (upstream), responses blocked (downstream)
          %{
            "name" => "pd_partition",
            "type" => "bandwidth",
            "stream" => "downstream",
            "attributes" => %{"rate" => 0}
          }
      end

    url = "#{api_url}/proxies/#{proxy_name}/toxics"

    case http_post(url, toxic) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:toxiproxy_error, reason}}
    end
  end

  defp restore_toxiproxy(_command, config) do
    proxy_name = config[:proxy_name] || "default"
    api_url = config[:api_url] || "http://localhost:8474"

    url = "#{api_url}/proxies/#{proxy_name}/toxics/pd_partition"

    case http_delete(url) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:toxiproxy_error, reason}}
    end
  end

  # ============================================================================
  # Simulated Mode
  # ============================================================================

  defp inject_simulated(_command, _context), do: :ok
  defp restore_simulated(_command, _context), do: :ok

  # ============================================================================
  # HTTP Helpers
  # ============================================================================

  defp http_post(url, body) do
    if Code.ensure_loaded?(:httpc) do
      uri = String.to_charlist(url)
      json_body = if Code.ensure_loaded?(Jason), do: Jason.encode!(body), else: inspect(body)

      case :httpc.request(:post, {uri, [], ~c"application/json", json_body}, [], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 -> {:ok, :created}
        {:ok, {{_, status, _}, _, _}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :httpc_not_available}
    end
  end

  defp http_delete(url) do
    if Code.ensure_loaded?(:httpc) do
      uri = String.to_charlist(url)

      case :httpc.request(:delete, {uri, []}, [], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 -> {:ok, :deleted}
        {:ok, {{_, 404, _}, _, _}} -> {:error, :not_found}
        {:ok, {{_, status, _}, _, _}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :httpc_not_available}
    end
  end
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
