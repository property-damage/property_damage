defmodule OpenapiBench.Generated.Model do
  @moduledoc """
  PropertyDamage model for API testing.

  Generated from OpenAPI spec. Customize command weights and add projections/assertions.
  """

  @behaviour PropertyDamage.Model

  alias OpenapiBench.Generated.Commands
  # alias OpenapiBench.Generated.Events
  # alias OpenapiBench.Generated.Projections

  @impl true
  def commands do
    [
      {5, Commands.GetValue},
      {2, Commands.PutValue}
    ]
  end

  @impl true
  def command_sequence_projection do
    # TODO: Add state tracking projection
    # Example: Projections.ResourceState
    raise "command_sequence_projection/0 not implemented - add your state projection module"
  end

  @impl true
  def assertion_projections do
    # TODO: Add extra projections (with @trigger/@poll_state assertions)
    # Example: [Projections.ResourceExists, Projections.ValidState]
    []
  end

  # Optional lifecycle callbacks
  # @impl true
  # def setup_once(config), do: {:ok, config}
  #
  # @impl true
  # def setup_each(config), do: {:ok, config}
  #
  # @impl true
  # def teardown_each(_config), do: :ok
  #
  # @impl true
  # def teardown_once(_config), do: :ok
end
