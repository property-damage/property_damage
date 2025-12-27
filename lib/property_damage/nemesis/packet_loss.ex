defmodule PropertyDamage.Nemesis.PacketLoss do
  @moduledoc """
  Simulate packet loss in network communication.

  Randomly drops a percentage of network packets, useful for testing
  retry logic, idempotency, and message delivery guarantees.

  ## Configuration

  - `:loss_percent` - Percentage of packets to drop (0-100, default: 10)
  - `:duration_ms` - How long packet loss persists (default: 5000ms)
  - `:target` - Specific service/host to affect (default: `:all`)

  ## Usage with Toxiproxy

      context = %{toxiproxy: %{proxy_name: "api", api_url: "http://localhost:8474"}}

  ## Example

      def commands do
        [
          {5, SendMessage},
          {1, PropertyDamage.Nemesis.PacketLoss}
        ]
      end

  ## Testing Behavior

  With packet loss, your system should:
  - Retry failed requests appropriately
  - Handle partial failures gracefully
  - Maintain consistency despite lost messages
  """

  @behaviour PropertyDamage.Nemesis

  defstruct loss_percent: 10,
            duration_ms: 5000,
            target: :all,
            injected_at: nil

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    not Map.has_key?(state[:active_faults] || %{}, :packet_loss)
  end

  @impl true
  def inject(%__MODULE__{} = command, context) do
    now = System.monotonic_time(:millisecond)
    command = %{command | injected_at: now}

    result =
      case get_toxiproxy(context) do
        {:ok, proxy_config} ->
          inject_toxiproxy(command, proxy_config)

        :not_configured ->
          :ok
      end

    case result do
      :ok ->
        event = %{
          __struct__: PacketLossInjected,
          loss_percent: command.loss_percent,
          target: command.target,
          injected_at: now
        }

        {:ok, [event]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def restore(%__MODULE__{} = command, context) do
    now = System.monotonic_time(:millisecond)

    result =
      case get_toxiproxy(context) do
        {:ok, proxy_config} ->
          restore_toxiproxy(proxy_config)

        :not_configured ->
          :ok
      end

    case result do
      :ok ->
        event = %{
          __struct__: PacketLossRestored,
          loss_percent: command.loss_percent,
          target: command.target,
          restored_at: now,
          duration_ms: now - (command.injected_at || now)
        }

        {:ok, [event]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(integer(5..50), fn loss ->
      bind(integer(1000..10000), fn duration ->
        constant(%__MODULE__{
          loss_percent: Map.get(overrides, :loss_percent, loss),
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

    # Toxiproxy doesn't have direct packet loss, use timeout toxic
    # to simulate dropped connections
    toxic = %{
      "name" => "pd_packet_loss",
      "type" => "timeout",
      "toxicity" => command.loss_percent / 100,
      "attributes" => %{"timeout" => 0}
    }

    url = "#{api_url}/proxies/#{proxy_name}/toxics"

    case http_post(url, toxic) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:toxiproxy_error, reason}}
    end
  end

  defp restore_toxiproxy(config) do
    proxy_name = config[:proxy_name] || "default"
    api_url = config[:api_url] || "http://localhost:8474"

    url = "#{api_url}/proxies/#{proxy_name}/toxics/pd_packet_loss"

    case http_delete(url) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:toxiproxy_error, reason}}
    end
  end

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
defmodule PacketLossInjected do
  @moduledoc "Event emitted when packet loss is injected"
  defstruct [:loss_percent, :target, :injected_at]
end

defmodule PacketLossRestored do
  @moduledoc "Event emitted when packet loss is restored"
  defstruct [:loss_percent, :target, :restored_at, :duration_ms]
end
