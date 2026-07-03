defmodule KratosBench.Model do
  @moduledoc """
  The model. `commands/0` defines the surface and the dependency chain: the three
  registration variants are always available (they add identities); `Login` and
  `DeleteIdentity` are gated on an existing identity and draw their target from
  state, so sequences interact. Registration emails are derived from a per-sequence
  counter so every registration is unique (no self-collision).

  Registration mostly succeeds (accept/modify outweigh reject) so runs build real
  state before exercising the reject path, per the mocking guide's "default to
  success" advice.
  """

  @behaviour PropertyDamage.Model

  alias KratosBench.Commands.{
    DeleteIdentity,
    ListIdentities,
    Login,
    RegisterAccept,
    RegisterModify,
    RegisterReject
  }

  @impl true
  def commands do
    [
      {RegisterAccept, weight: 4, with: &register_overrides/1},
      {RegisterModify, weight: 2, with: &register_overrides/1},
      {RegisterReject, weight: 2, with: &register_overrides/1},
      {ListIdentities, weight: 3},
      {Login, weight: 2, when: &has_identity?/1, with: &login_overrides/1},
      {DeleteIdentity, weight: 1, when: &has_identity?/1, with: &delete_overrides/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: KratosBench.State

  @impl true
  def assertion_projections, do: [KratosBench.State]

  @impl true
  def simulator, do: KratosBench.Simulator

  # --- preconditions ---------------------------------------------------------

  def has_identity?(state), do: map_size(state.identities) > 0

  # --- parameterization ------------------------------------------------------

  def register_overrides(state) do
    %{email: StreamData.constant(KratosBench.email_for(state.reg_count))}
  end

  def login_overrides(state) do
    %{
      email: StreamData.member_of(Map.keys(state.identities)),
      password: StreamData.constant(Application.fetch_env!(:kratos_bench, :password))
    }
  end

  def delete_overrides(state) do
    %{email: StreamData.member_of(Map.keys(state.identities))}
  end
end
