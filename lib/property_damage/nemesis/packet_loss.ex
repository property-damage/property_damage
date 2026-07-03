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

  Live injection needs Toxiproxy configured in the adapter context. Return it
  from your adapter's `setup/1` (DR-038):

      def setup(_config) do
        {:ok, %{toxiproxy: %{proxy_name: "api", api_url: "http://localhost:8474"}}}
      end

  A top-level `:toxiproxy` key on the context is also honored for direct
  `inject/2` calls.

  ## Example

      def commands do
        [
          {SendMessage, weight: 5},
          {PropertyDamage.Nemesis.PacketLoss, weight: 1}
        ]
      end

  ## Testing Behavior

  With packet loss, your system should:
  - Retry failed requests appropriately
  - Handle partial failures gracefully
  - Maintain consistency despite lost messages
  """

  @behaviour PropertyDamage.Nemesis

  alias PropertyDamage.Nemesis.Toxiproxy

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

    {result, simulated?} = Toxiproxy.inject_toxics(context, toxics(command))

    case result do
      :ok ->
        event = %{
          __struct__: PacketLossInjected,
          loss_percent: command.loss_percent,
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
          __struct__: PacketLossRestored,
          loss_percent: command.loss_percent,
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

    bind(integer(5..50), fn loss ->
      bind(integer(1000..10_000), fn duration ->
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
  # Toxic spec (pure)
  # ============================================================================

  @doc """
  The Toxiproxy toxics this command injects, as pure JSON-encodable maps.

  Toxiproxy has no direct packet-loss toxic, so loss is modeled with a `timeout`
  toxic at `timeout: 0` (drop the connection) whose `toxicity` is the loss
  fraction (`loss_percent / 100`), i.e. the probability the toxic fires per
  connection.
  """
  @spec toxics(%__MODULE__{}) :: [Toxiproxy.toxic()]
  def toxics(%__MODULE__{} = command) do
    [
      %{
        "name" => "pd_packet_loss",
        "type" => "timeout",
        "toxicity" => command.loss_percent / 100,
        "attributes" => %{"timeout" => 0}
      }
    ]
  end

  defp toxic_names(command), do: Enum.map(toxics(command), & &1["name"])
end

# Event structs
defmodule PacketLossInjected do
  @moduledoc false
  defstruct [:loss_percent, :target, :injected_at, simulated: false]
end

defmodule PacketLossRestored do
  @moduledoc false
  defstruct [:loss_percent, :target, :restored_at, :duration_ms, simulated: false]
end
