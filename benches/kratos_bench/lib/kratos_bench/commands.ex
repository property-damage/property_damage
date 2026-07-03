defmodule KratosBench.Commands do
  @moduledoc """
  Transport-agnostic command intents. Every field is supplied by the model's
  `with:` overrides (derived from the generation-time projection state), so base
  generators are `nil` — the standard PropertyDamage pattern.

  The three `Register*` variants differ only in the mock behaviour they request:
  the mock's `on_command/2` reads the command type and sets its decision, so the
  same web_hook accepts, rejects, or rewrites the identity depending on which
  command is executing.
  """

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  alias KratosBench.Events.{
    IdentitiesListed,
    IdentityDeleted,
    LoginAttempted,
    RegistrationHandled
  }

  defmodule RegisterAccept do
    @moduledoc "Register an identity the mock will accept (2xx, no changes)."
    use PropertyDamage.Command, observables: [RegistrationHandled]

    defstruct [:email]

    @impl true
    def generator(overrides \\ %{}) do
      %{email: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule RegisterReject do
    @moduledoc "Register an identity the mock will reject (4xx): no identity must persist."
    use PropertyDamage.Command, observables: [RegistrationHandled]

    defstruct [:email]

    @impl true
    def generator(overrides \\ %{}) do
      %{email: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule RegisterModify do
    @moduledoc "Register an identity the mock accepts (2xx) while rewriting its role trait."
    use PropertyDamage.Command, observables: [RegistrationHandled]

    defstruct [:email]

    @impl true
    def generator(overrides \\ %{}) do
      %{email: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Login do
    @moduledoc "Log in as an existing identity. email/password injected by the model."
    use PropertyDamage.Command, observables: [LoginAttempted]

    defstruct [:email, :password]

    @impl true
    def generator(overrides \\ %{}) do
      %{email: StreamData.constant(nil), password: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule ListIdentities do
    @moduledoc "Read Kratos's identity set back (the reality the invariants check)."
    use PropertyDamage.Command, observables: [IdentitiesListed]

    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule DeleteIdentity do
    @moduledoc "Delete an existing identity via the admin API. email injected by the model."
    use PropertyDamage.Command, observables: [IdentityDeleted]

    defstruct [:email]

    @impl true
    def generator(overrides \\ %{}) do
      %{email: StreamData.constant(nil)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
end
