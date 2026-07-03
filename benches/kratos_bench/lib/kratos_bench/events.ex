defmodule KratosBench.Events do
  @moduledoc """
  Events folded by `KratosBench.State`.

  `RegistrationHandled` is injected by the mock (via the MockServiceRegistry) when
  Kratos calls its web_hook: it records what the mock *decided*, i.e. the model's
  expectation of Kratos state. `IdentitiesListed` and `LoginAttempted` carry the
  observed *reality* the adapter reads back from Kratos, and the assertions in
  `KratosBench.State` check reality against expectation.
  """

  defmodule RegistrationHandled do
    @moduledoc "The mock's decision for one registration: :accept, :reject or :modify."
    defstruct [:email, :decision, :role]
  end

  defmodule IdentityDeleted do
    @moduledoc "The adapter deleted an identity via the admin API."
    defstruct [:email]
  end

  defmodule IdentitiesListed do
    @moduledoc "Snapshot of Kratos's identities: `identities` is `%{email => %{role:}}`."
    defstruct [:identities]
  end

  defmodule LoginAttempted do
    @moduledoc "A login attempt and its observed outcome (:success | :failure)."
    defstruct [:email, :outcome]
  end
end
