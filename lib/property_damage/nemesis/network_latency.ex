defmodule PropertyDamage.Nemesis.NetworkLatency do
  @moduledoc """
  Inject network latency into the test environment.

  Simulates slow network conditions by adding delay to network operations.
  Useful for testing timeout handling, retry logic, and degraded performance.

  ## Configuration

  - `:latency_ms` - Base latency to add (default: 100ms)
  - `:jitter_ms` - Random jitter ± this value (default: 0)
  - `:duration_ms` - How long the latency persists (default: 5000ms)
  - `:target` - What to affect: `:all`, `:upstream`, `:downstream`, or specific host

  ## Usage with Toxiproxy

  When using Toxiproxy, set `:toxiproxy` in the adapter context:

      context = %{toxiproxy: %{proxy_name: "my_service", api_url: "http://localhost:8474"}}

  ## Simulated Mode

  Without Toxiproxy, operates in simulated mode where latency is tracked
  in state but not actually injected. Useful for testing nemesis logic.

  ## Example

      defmodule MyModel do
        def commands do
          [
            {5, CreateOrder},
            {1, PropertyDamage.Nemesis.NetworkLatency}  # Low weight for chaos
          ]
        end
      end

  ## Events

  Emits `%NetworkLatencyInjected{}` on inject and `%NetworkLatencyRestored{}` on restore.
  """

  @behaviour PropertyDamage.Nemesis

  defstruct latency_ms: 100,
            jitter_ms: 0,
            duration_ms: 5000,
            target: :all,
            injected_at: nil

  # ============================================================================
  # Nemesis Callbacks
  # ============================================================================

  @impl true
  def precondition(state) do
    # Don't inject if latency already active
    not Map.has_key?(state[:active_faults] || %{}, :network_latency)
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
          __struct__: NetworkLatencyInjected,
          latency_ms: command.latency_ms,
          jitter_ms: command.jitter_ms,
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
          __struct__: NetworkLatencyRestored,
          latency_ms: command.latency_ms,
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

  @impl true
  def new!(_state, overrides \\ %{}) do
    import StreamData

    bind(integer(50..500), fn latency ->
      bind(integer(0..50), fn jitter ->
        bind(integer(1000..10_000), fn duration ->
          constant(%__MODULE__{
            latency_ms: Map.get(overrides, :latency_ms, latency),
            jitter_ms: Map.get(overrides, :jitter_ms, jitter),
            duration_ms: Map.get(overrides, :duration_ms, duration),
            target: Map.get(overrides, :target, :all)
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
  # Toxiproxy Integration
  # ============================================================================

  defp get_toxiproxy(%{toxiproxy: config}) when is_map(config), do: {:ok, config}
  defp get_toxiproxy(_), do: :not_configured

  defp inject_toxiproxy(command, config) do
    proxy_name = config[:proxy_name] || "default"
    api_url = config[:api_url] || "http://localhost:8474"

    toxic = %{
      "name" => "pd_latency",
      "type" => "latency",
      "attributes" => %{
        "latency" => command.latency_ms,
        "jitter" => command.jitter_ms
      }
    }

    url = "#{api_url}/proxies/#{proxy_name}/toxics"

    case http_post(url, toxic) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:toxiproxy_error, reason}}
    end
  end

  defp restore_toxiproxy(_command, config) do
    proxy_name = config[:proxy_name] || "default"
    api_url = config[:api_url] || "http://localhost:8474"

    url = "#{api_url}/proxies/#{proxy_name}/toxics/pd_latency"

    case http_delete(url) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:toxiproxy_error, reason}}
    end
  end

  # ============================================================================
  # Simulated Mode
  # ============================================================================

  defp inject_simulated(_command, _context) do
    # In simulated mode, just record that latency is active
    # The adapter can check state.active_faults[:network_latency] and add delay
    :ok
  end

  defp restore_simulated(_command, _context) do
    :ok
  end

  # ============================================================================
  # HTTP Helpers (minimal implementation)
  # ============================================================================

  defp http_post(url, body) do
    if Code.ensure_loaded?(:httpc) do
      uri = String.to_charlist(url)
      json_body = if Code.ensure_loaded?(Jason), do: Jason.encode!(body), else: inspect(body)

      case :httpc.request(
             :post,
             {uri, [], ~c"application/json", json_body},
             [],
             []
           ) do
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
defmodule NetworkLatencyInjected do
  @moduledoc """
  Event emitted when network latency is injected.

  `simulated: true` means no real latency was injected (no Toxiproxy was
  configured); the fault is a no-op recorded honestly so it can never
  masquerade as a real one.
  """
  defstruct [:latency_ms, :jitter_ms, :target, :injected_at, simulated: false]
end

defmodule NetworkLatencyRestored do
  @moduledoc "Event emitted when network latency is restored"
  defstruct [:latency_ms, :target, :restored_at, :duration_ms, simulated: false]
end
