defmodule OpenapiBench.Generated.Model do
  @moduledoc """
  PropertyDamage model for API testing.

  Generated from OpenAPI spec. Customize command weights and add projections/checks.
  """

  @behaviour PropertyDamage.Model

  alias OpenapiBench.Generated.Commands

  @impl true
  def commands do
    # Balanced reads/writes so PUT/GET collide on the small 0..4 key space and
    # the read-consistency invariant is actually exercised.
    [
      {Commands.GetValue, weight: 4},
      {Commands.PutValue, weight: 4}
    ]
  end

  @impl true
  def command_sequence_projection, do: OpenapiBench.Consistency

  @impl true
  def check_projections, do: [OpenapiBench.Consistency]

  @impl true
  def simulator, do: OpenapiBench.Simulator
end
