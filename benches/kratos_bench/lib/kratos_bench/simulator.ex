defmodule KratosBench.Simulator do
  @moduledoc """
  Predicts one event per command during generation, before Kratos is touched, so
  `KratosBench.State` advances and `when:`/`with:` can pick coherent targets.

  Without this the `when:`-gated `Login`/`DeleteIdentity` commands would never be
  generated (the projection would stay empty during the symbolic phase). The
  registration predictions mirror the mock's decision so the expected identity set
  is identical in generation and execution.
  """

  @behaviour PropertyDamage.Model.Simulator

  alias KratosBench.Commands.{
    DeleteIdentity,
    Login,
    RegisterAccept,
    RegisterModify,
    RegisterReject
  }

  alias KratosBench.Events.{IdentityDeleted, RegistrationHandled}

  @impl true
  def simulate(%RegisterAccept{email: email}, _state) do
    [%RegistrationHandled{email: email, decision: :accept, role: nil}]
  end

  def simulate(%RegisterReject{email: email}, _state) do
    [%RegistrationHandled{email: email, decision: :reject, role: nil}]
  end

  def simulate(%RegisterModify{email: email}, _state) do
    [%RegistrationHandled{email: email, decision: :modify, role: KratosBench.mock_role()}]
  end

  def simulate(%DeleteIdentity{email: email}, _state) do
    [%IdentityDeleted{email: email}]
  end

  # Login and ListIdentities don't change the model's identity set.
  def simulate(%Login{}, _state), do: []
  def simulate(_command, _state), do: []
end
