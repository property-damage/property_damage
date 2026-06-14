defmodule OpenapiBench.Consistency do
  @moduledoc """
  Read-consistency invariant over the generated KV client (scaffold next-steps
  4 & 6: the projection + assertion the scaffold leaves to the user).

  The model tallies what each key should hold from the `PutValueCompleted`
  events the generated adapter returns, and every `GetValue` must observe that
  value (or `:unset` for a key never written, which the API answers with a
  404). A `200` carrying the wrong value or a `404` where a value was stored is
  a read-consistency violation.
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

  @trigger every: GetValue
  def assert_read_consistent(state, _command) do
    case state.last_read do
      {key, observed} ->
        expected = Map.get(state.store, key, :unset)

        if observed != expected do
          PropertyDamage.fail!(
            "GET key=#{key} returned #{inspect(observed)}, model expects #{inspect(expected)}",
            key: key,
            actual: observed,
            expected: expected
          )
        end

      nil ->
        :ok
    end
  end
end
