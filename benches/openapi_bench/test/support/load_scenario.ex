defmodule OpenapiBench.LoadConsistency do
  @moduledoc """
  Read-your-own-write invariant for the load-test scenario.

  Under load the SUT is shared by many concurrent worker sessions and is never
  reset between a worker's sequences (the load-test worker keeps its adapter
  context for the whole run). So this projection only checks reads of keys it
  observed a write for *in the current sequence*: those are the reads whose
  expected value this sequence itself established. A read of a key never written
  this sequence may legitimately observe leftover state from an earlier sequence
  and is not asserted on. Cross-worker interference is ruled out separately by
  `OpenapiBench.LoadAdapter`, which namespaces every key per worker.

  This still catches the seeded dropped-write bug: a `PutValue` that answers 200
  but silently drops the write records an expected value here, while the
  following `GetValue` on that key observes `:unset` (404) instead.
  """
  use PropertyDamage.Model.Projection

  alias OpenapiBench.Generated.Commands.GetValue
  alias OpenapiBench.Generated.Events.{PutValueCompleted, ValueRetrieved}

  @impl true
  def init, do: %{store: %{}, last_read: nil}

  @impl true
  def apply(state, %PutValueCompleted{key: key, value: value}) do
    %{state | store: Map.put(state.store, key, value)}
  end

  def apply(state, %ValueRetrieved{key: key, value: value}) do
    %{state | last_read: {key, value}}
  end

  def apply(state, _event), do: state

  @invariant id: :read_your_write,
             description: "A read of a key written this sequence returns the written value"

  @trigger every: GetValue, validates: :read_your_write
  def assert_read_your_write(state, _command) do
    with {key, observed} <- state.last_read,
         expected when expected != :unset <- Map.get(state.store, key, :unset) do
      if observed != expected do
        PropertyDamage.fail!(
          "GET key=#{key} returned #{inspect(observed)}, model wrote #{inspect(expected)} this sequence",
          key: key,
          actual: observed,
          expected: expected
        )
      end
    else
      _ -> :ok
    end
  end
end

defmodule OpenapiBench.LoadSimulator do
  @moduledoc "Predicts events during generation for the load-test model."
  @behaviour PropertyDamage.Model.Simulator

  alias OpenapiBench.Generated.Commands.{GetValue, PutValue}
  alias OpenapiBench.Generated.Events.{PutValueCompleted, ValueRetrieved}

  @impl true
  def simulate(%PutValue{key: key, value: value}, _state) do
    [%PutValueCompleted{key: key, value: value}]
  end

  def simulate(%GetValue{key: key}, state) do
    [%ValueRetrieved{key: key, value: Map.get(state.store, key, :unset)}]
  end

  def simulate(_command, _state), do: []
end

defmodule OpenapiBench.LoadModel do
  @moduledoc """
  A read/write-balanced model for load testing the KV API. Reuses the generated
  PutValue/GetValue commands and events; the difference from the scaffold model
  is `OpenapiBench.LoadConsistency` (read-your-own-write, robust to the shared,
  never-reset SUT a load test drives).
  """
  @behaviour PropertyDamage.Model

  alias OpenapiBench.Generated.Commands.{GetValue, PutValue}

  @impl true
  def commands, do: [{PutValue, weight: 5}, {GetValue, weight: 5}]

  @impl true
  def command_sequence_projection, do: OpenapiBench.LoadConsistency

  @impl true
  def assertion_projections, do: [OpenapiBench.LoadConsistency]

  @impl true
  def simulator, do: OpenapiBench.LoadSimulator
end

defmodule OpenapiBench.LoadAdapter do
  @moduledoc """
  HTTP adapter for the load-test scenario.

  Identical to the generated adapter except every key is namespaced per worker:
  `setup/1` mints a unique namespace and each request maps the model key `k`
  (0..4) to a globally distinct server key. Because concurrent load-test workers
  each get their own namespace, they never collide on a shared key, so the
  read-your-own-write invariant is meaningful under concurrency. Within a worker,
  sequences run one at a time, so the namespace is used serially.
  """
  use PropertyDamage.Adapter

  alias OpenapiBench.Generated.Commands.{GetValue, PutValue}
  alias OpenapiBench.Generated.Events.{PutValueCompleted, ValueRetrieved}

  @impl true
  def setup(config) do
    Application.ensure_all_started(:inets)
    base_url = Map.fetch!(config, :base_url)
    {:ok, %{base_url: base_url, ns: System.unique_integer([:positive])}}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%PutValue{key: key, value: value}, ctx, _runtime) do
    case request(:put, url(ctx, key), %{value: value}) do
      {200, _body} -> {:ok, [%PutValueCompleted{key: key, value: value}]}
      {_status, _body} -> {:ok, []}
    end
  end

  def execute(%GetValue{key: key}, ctx, _runtime) do
    case request(:get, url(ctx, key), nil) do
      {200, %{"value" => value}} -> {:ok, [%ValueRetrieved{key: key, value: value}]}
      {404, _body} -> {:ok, [%ValueRetrieved{key: key, value: :unset}]}
      {_status, _body} -> {:ok, []}
    end
  end

  # Model key 0..4 → a server key unique to this worker's namespace. The *8
  # spacing exceeds the 0..4 key range, so distinct namespaces never overlap.
  defp url(%{base_url: base_url, ns: ns}, key), do: "#{base_url}/kv/#{ns * 8 + key}"

  defp request(method, url, body) do
    headers = [{~c"content-type", ~c"application/json"}]

    request =
      case method do
        :get -> {String.to_charlist(url), headers}
        _ -> {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body || %{})}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {status, decode(resp_body)}
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
