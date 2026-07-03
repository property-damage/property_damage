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

  Live injection needs Toxiproxy configured in the adapter context. Return it
  from your adapter's `setup/1` (DR-038):

      def setup(_config) do
        {:ok, %{toxiproxy: %{proxy_name: "my_service", api_url: "http://localhost:8474"}}}
      end

  A top-level `:toxiproxy` key on the context is also honored for direct
  `inject/2` calls.

  ## Simulated Mode

  Without Toxiproxy, operates in simulated mode: no latency is injected and the
  emitted event is tagged `simulated: true` so a no-op can never masquerade as a
  real fault. See `PropertyDamage.Nemesis.simulated_event?/1`.

  ## Example

      defmodule MyModel do
        def commands do
          [
            {CreateOrder, weight: 5},
            {PropertyDamage.Nemesis.NetworkLatency, weight: 1}  # Low weight for chaos
          ]
        end
      end

  ## Events

  Emits `%NetworkLatencyInjected{}` on inject and `%NetworkLatencyRestored{}` on restore.
  """

  @behaviour PropertyDamage.Nemesis

  alias PropertyDamage.Nemesis.Toxiproxy

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

    {result, simulated?} = Toxiproxy.inject_toxics(context, toxics(command))

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

    {result, simulated?} = Toxiproxy.restore_toxics(context, toxic_names(command))

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

  @spec new!(map(), map()) :: StreamData.t(struct())
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
  # Toxic spec (pure)
  # ============================================================================

  @doc """
  The Toxiproxy toxics this command injects, as pure JSON-encodable maps.

  A latency command is a single `latency` toxic carrying the base latency and
  jitter (in milliseconds).
  """
  @spec toxics(%__MODULE__{}) :: [Toxiproxy.toxic()]
  def toxics(%__MODULE__{} = command) do
    [
      %{
        "name" => "pd_latency",
        "type" => "latency",
        "attributes" => %{
          "latency" => command.latency_ms,
          "jitter" => command.jitter_ms
        }
      }
    ]
  end

  defp toxic_names(command), do: Enum.map(toxics(command), & &1["name"])
end

# Event structs
defmodule NetworkLatencyInjected do
  @moduledoc false
  defstruct [:latency_ms, :jitter_ms, :target, :injected_at, simulated: false]
end

defmodule NetworkLatencyRestored do
  @moduledoc false
  defstruct [:latency_ms, :target, :restored_at, :duration_ms, simulated: false]
end
