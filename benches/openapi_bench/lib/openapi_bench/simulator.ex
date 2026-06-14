defmodule OpenapiBench.Simulator do
  @moduledoc """
  Predicts events during generation (scaffold next-step 4), before any HTTP call
  exists, so the consistency projection can evolve while sequences are built.

  A `PutValue` stores its value; a `GetValue` is predicted to read whatever the
  model currently holds for that key (`:unset` if never written).
  """
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
