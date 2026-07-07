defmodule OpenapiBench.Idempotency.Events.ValueCreated do
  @moduledoc "Event: `POST /values` returned a server-assigned id."
  defstruct [:id, :value]
end

defmodule OpenapiBench.Idempotency.Commands.CreateValue do
  @moduledoc """
  Create a value via the non-idempotent `POST /values` endpoint.

  Each instance carries a unique `token` that becomes its `Idempotency-Key`, so
  a client (the adapter) can safely retry the *same* create. The framework's
  stutter testing retries the command and compares events: a retry-safe SUT
  returns the original id (match); a SUT that ignores the key double-creates
  (mismatch = idempotency violation).
  """
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:value, :token]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      value: StreamData.integer(0..100),
      # A client-minted, run-scoped idempotency token (DR-034). During
      # generation the field holds a mint marker reified with its coordinates,
      # so the plan stays a pure function of the seed; at execution it resolves
      # to a UUID derived from the run's nonce/epoch and those coordinates.
      # Unlike a bounded integer, this is unique per run and thus collision-safe
      # against the advertised non-resettable external SUT (PD_OPENAPI_URL).
      token: StreamData.constant(PropertyDamage.mint_per_run(:uuid))
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # The idempotency key the client sends on every attempt (first + retries) for
  # this logical create. Stable per instance, unique across instances.
  @impl true
  def idempotency_key(%__MODULE__{token: token}), do: "create-#{token}"
end

defmodule OpenapiBench.Idempotency.Adapter do
  @moduledoc """
  Drives `POST /values` for the idempotency bench. It attaches the command's
  `Idempotency-Key` on *every* attempt (the standard safe-retry client pattern),
  so the SUT can dedupe retries unless the `idempotency_bug` flag is seeded.
  """
  use PropertyDamage.Adapter

  alias OpenapiBench.Idempotency.Commands.CreateValue
  alias OpenapiBench.Idempotency.Events.ValueCreated

  @impl true
  def setup(config) do
    {:ok, Map.put_new(config, :base_url, OpenapiBench.Server.base_url())}
  end

  @impl true
  def teardown(_config), do: :ok

  @impl true
  def execute(%CreateValue{value: value} = cmd, ctx, _runtime) do
    key = CreateValue.idempotency_key(cmd)

    case post_json(ctx.base_url <> "/values", %{value: value}, [{"Idempotency-Key", key}]) do
      {:ok, 201, %{"id" => id, "value" => v}} -> {:ok, [%ValueCreated{id: id, value: v}]}
      {:ok, status, body} -> {:error, {:unexpected_response, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_json(url, body, headers) do
    Application.ensure_all_started(:inets)

    req_headers =
      Enum.map([{"content-type", "application/json"} | headers], fn {k, v} ->
        {to_charlist(k), to_charlist(v)}
      end)

    request = {String.to_charlist(url), req_headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {:ok, status, decode(resp_body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end

defmodule OpenapiBench.Idempotency.Projection do
  @moduledoc "Counts creates so a run can prove `CreateValue` actually executed."
  use PropertyDamage.Model.Projection

  alias OpenapiBench.Idempotency.Events.ValueCreated

  @impl true
  def init, do: %{creates: 0}

  @impl true
  def apply(state, %ValueCreated{}), do: %{state | creates: state.creates + 1}
  def apply(state, _event), do: state
end

defmodule OpenapiBench.Idempotency.Simulator do
  @moduledoc """
  Predicts a create during generation. The real id is server-assigned, so the
  simulated event carries `:pending`; nothing asserts on it (stutter compares
  real retry events at execution time, not against the simulation).
  """
  @behaviour PropertyDamage.Model.Simulator

  alias OpenapiBench.Idempotency.Commands.CreateValue
  alias OpenapiBench.Idempotency.Events.ValueCreated

  @impl true
  def simulate(%CreateValue{value: value}, _state),
    do: [%ValueCreated{id: :pending, value: value}]

  def simulate(_command, _state), do: []
end

defmodule OpenapiBench.Idempotency.Model do
  @moduledoc """
  Idempotency bench model: sequences of `CreateValue` against `POST /values`.
  `setup_each/1` seeds the `idempotency_bug` flag from `adapter_config` so the
  same model exercises both the retry-safe and the double-creating SUT.
  """
  @behaviour PropertyDamage.Model

  alias OpenapiBench.Idempotency.Commands.CreateValue

  @impl true
  def commands, do: [{CreateValue, weight: 1}]

  @impl true
  def command_sequence_projection, do: OpenapiBench.Idempotency.Projection

  @impl true
  def simulator, do: OpenapiBench.Idempotency.Simulator

  @impl true
  def setup_each(%{adapter_config: config}) do
    OpenapiBench.Server.reset(false, Map.get(config, :idempotency_bug, false))
    :ok
  end
end
