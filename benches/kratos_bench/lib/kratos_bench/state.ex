defmodule KratosBench.State do
  @moduledoc """
  The model's expectation of Kratos, doubling as the assertion projection.

  During generation it is fed the simulator's predicted events so `when:`/`with:`
  can pick coherent targets (an existing identity to log in as or delete); during
  execution it is fed the real events. `RegistrationHandled` (injected by the mock)
  advances the *expected* identity set: an accepted or modified registration adds
  the email (modify also records the mock-assigned role); a rejected one adds
  nothing. `IdentitiesListed` and `LoginAttempted` carry the observed reality the
  assertions check against that expectation.
  """

  use PropertyDamage.Model.Projection

  alias KratosBench.Events.{
    IdentitiesListed,
    IdentityDeleted,
    LoginAttempted,
    RegistrationHandled
  }

  # DR-026 invariant catalog: the properties the assertions below uphold.
  @invariant id: :identity_set_faithful,
             description:
               "Kratos holds exactly the identities the mock accepted; a rejected registration leaves none"
  @invariant id: :accepted_traits_faithful,
             description:
               "An identity the mock modified carries the role trait the mock's response dictated"
  @invariant id: :login_consistent,
             description: "Login succeeds exactly for identities the mock let Kratos create"

  @impl true
  def init, do: %{identities: %{}, reg_count: 0}

  @impl true
  def apply(state, %RegistrationHandled{decision: :reject}) do
    # A rejected registration never creates an identity, but it did consume a
    # client-chosen email, so advance the counter to keep emails unique.
    update_in(state.reg_count, &(&1 + 1))
  end

  def apply(state, %RegistrationHandled{email: email, decision: :accept}) do
    state
    |> put_in([:identities, email], %{role: nil})
    |> update_in([:reg_count], &(&1 + 1))
  end

  def apply(state, %RegistrationHandled{email: email, decision: :modify, role: role}) do
    state
    |> put_in([:identities, email], %{role: role})
    |> update_in([:reg_count], &(&1 + 1))
  end

  def apply(state, %IdentityDeleted{email: email}) do
    update_in(state.identities, &Map.delete(&1, email))
  end

  def apply(state, _event), do: state

  # --- assertions ------------------------------------------------------------

  @trigger every: IdentitiesListed, validates: :identity_set_faithful
  def assert_identity_set(state, %IdentitiesListed{identities: listed}) do
    expected = state.identities |> Map.keys() |> MapSet.new()
    actual = listed |> Map.keys() |> MapSet.new()

    if expected != actual do
      PropertyDamage.fail!("Kratos identity set diverged from the model",
        expected: Enum.sort(expected),
        observed: Enum.sort(actual),
        leaked: MapSet.difference(actual, expected) |> Enum.sort(),
        missing: MapSet.difference(expected, actual) |> Enum.sort()
      )
    end
  end

  @trigger every: IdentitiesListed, validates: :accepted_traits_faithful
  def assert_traits(state, %IdentitiesListed{identities: listed}) do
    for {email, %{role: expected_role}} <- state.identities, Map.has_key?(listed, email) do
      observed_role = get_in(listed, [email, :role])

      if expected_role != observed_role do
        PropertyDamage.fail!("identity carries the wrong role trait",
          email: email,
          expected_role: expected_role,
          observed_role: observed_role
        )
      end
    end
  end

  @trigger every: LoginAttempted, validates: :login_consistent
  def assert_login(state, %LoginAttempted{email: email, outcome: outcome}) do
    expected = if Map.has_key?(state.identities, email), do: :success, else: :failure

    if outcome != expected do
      PropertyDamage.fail!("login outcome inconsistent with model state",
        email: email,
        expected: expected,
        observed: outcome,
        known_identity?: Map.has_key?(state.identities, email)
      )
    end
  end
end
