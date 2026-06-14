defmodule OpenapiBench.Generated.Model do
  @moduledoc """
  PropertyDamage model for API testing.

  Generated from OpenAPI spec. Customize command weights and add projections/assertions.
  """

  @behaviour PropertyDamage.Model

  alias OpenapiBench.Generated.Commands

  @impl true
  def commands do
    # Balanced reads/writes so PUT/GET collide on the small 0..4 key space and
    # the read-consistency invariant is actually exercised.
    [
      {4, Commands.GetValue},
      {4, Commands.PutValue}
    ]
  end

  @impl true
  def command_sequence_projection, do: OpenapiBench.Consistency

  @impl true
  def assertion_projections, do: [OpenapiBench.Consistency]

  @impl true
  def simulator, do: OpenapiBench.Simulator

  # Reset the SUT between sequences (and shrink attempts) so runs never share
  # key/value state. The `bug` flag (default false) rides in adapter_config and
  # seeds the read-consistency violation for the non-vacuity test.
  @impl true
  def setup_each(%{adapter_config: config}) do
    OpenapiBench.Server.reset(Map.get(config, :bug, false))
    :ok
  end
end
