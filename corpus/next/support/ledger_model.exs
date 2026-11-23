# The ledger model, written for the new engine: a port of the default corpus
# directory's ledger model. It drives the same system, `Corpus.Ledger`: open
# one account, deposit 1 to 20 into it, withdraw from it any amount up to its
# balance, and check after every deposit and withdrawal that the balance the
# ledger reports equals the one rebuilt from the amounts of the events.

Code.require_file("../../support/ledger.exs", __DIR__)

defmodule Corpus.Next.Ledger.Events do
  @moduledoc "What happened against the ledger."

  defmodule AccountOpened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:currency, id: external()]
  end

  defmodule Deposited do
    @moduledoc false
    # `balance` is the account's balance after the deposit, as the ledger reports it.
    defstruct [:account_id, :amount, :balance]
  end

  defmodule Withdrawn do
    @moduledoc false
    # `balance` is the account's balance after the withdrawal, as the ledger reports it.
    defstruct [:account_id, :amount, :balance]
  end
end

defmodule Corpus.Next.Ledger.Open do
  @moduledoc "Open the account. The system mints its id."
  use PropertyDamage.Next.Command

  defstruct [:currency]

  def generator(_state, _opts), do: %{currency: member_of(["USD"])}
end

defmodule Corpus.Next.Ledger.Deposit do
  @moduledoc "Put 1 to 20 into the open account."
  use PropertyDamage.Next.Command

  defstruct [:account_id, :amount]

  def generator(state, _opts),
    do: %{account_id: member_of([state.account]), amount: integer(1..20)}
end

defmodule Corpus.Next.Ledger.Withdraw do
  @moduledoc """
  Take money out of the open account: an amount from 1 up to its balance,
  which can be more than a deposit's 20.
  """
  use PropertyDamage.Next.Command

  defstruct [:account_id, :amount]

  def generator(state, _opts),
    do: %{account_id: member_of([state.account]), amount: integer(1..state.balance)}
end

defmodule Corpus.Next.Ledger.World do
  @moduledoc """
  The sequence projection: the open account's id and the balance the model
  expects.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Ledger.Events.{AccountOpened, Deposited, Withdrawn}

  @impl true
  def init, do: %{account: nil, balance: 0}

  @impl true
  def apply(state, %AccountOpened{id: id}), do: %{state | account: id}
  def apply(state, %Deposited{amount: amount}), do: %{state | balance: state.balance + amount}
  def apply(state, %Withdrawn{amount: amount}), do: %{state | balance: state.balance - amount}
  def apply(state, _other), do: state

  @doc "Whether an account is open."
  def open?(state), do: state.account != nil

  @doc "Whether the open account holds money to withdraw."
  def funded?(state), do: state.account != nil and state.balance > 0
end

defmodule Corpus.Next.Ledger.LedgerMatch do
  @moduledoc """
  Check projection: the balance the ledger reports equals the one rebuilt from
  the amounts the events carry.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Ledger.Events.{Deposited, Withdrawn}

  @impl true
  def init, do: %{ledger: 0, reported: 0}

  @impl true
  def apply(state, %Deposited{amount: amount, balance: balance}),
    do: %{state | ledger: state.ledger + amount, reported: balance}

  def apply(state, %Withdrawn{amount: amount, balance: balance}),
    do: %{state | ledger: state.ledger - amount, reported: balance}

  def apply(state, _other), do: state

  @check every: 1
  def assert_balance_matches_ledger(state, _cmd_or_event) do
    state.reported == state.ledger or
      PropertyDamage.fail!("Reported balance differs from the ledger",
        drift: state.reported - state.ledger
      )
  end
end

defmodule Corpus.Next.Ledger.Simulator do
  @moduledoc "Predicts the events of a command before any ledger exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Next.Ledger.Events.{AccountOpened, Deposited, Withdrawn}
  alias Corpus.Next.Ledger.{Deposit, Open, Withdraw}

  @impl true
  def simulate(%Open{currency: currency}, _state), do: [%AccountOpened{currency: currency}]

  def simulate(%Deposit{account_id: id, amount: amount}, state),
    do: [%Deposited{account_id: id, amount: amount, balance: state.balance + amount}]

  def simulate(%Withdraw{account_id: id, amount: amount}, state),
    do: [%Withdrawn{account_id: id, amount: amount, balance: state.balance - amount}]
end

defmodule Corpus.Next.Ledger.Model do
  @moduledoc "Open one account, then deposit into it and withdraw from it."
  use PropertyDamage.Next.Model

  alias Corpus.Next.Ledger.{Deposit, LedgerMatch, Open, Withdraw, World}
  alias PropertyDamage.Next.StepSpec

  def steps do
    StepSpec.normalize([
      {Open, when: &(not World.open?(&1))},
      {Deposit, when: &World.open?/1},
      {Withdraw, when: &World.funded?/1}
    ])
  end

  def command_sequence_projection, do: World
  def check_projections, do: [LedgerMatch]
  def simulator, do: Corpus.Next.Ledger.Simulator
end

defmodule Corpus.Next.Ledger.Adapter do
  @moduledoc """
  Runs the ledger commands against a `Corpus.Ledger` started with the entry's
  `:bug` and `:fire_log`, taken from the run's config.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Ledger
  alias Corpus.Next.Ledger.Events.{AccountOpened, Deposited, Withdrawn}
  alias Corpus.Next.Ledger.{Deposit, Open, Withdraw}

  @impl true
  def setup(config, _runtime) do
    {:ok, ledger} = Ledger.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{ledger: ledger}}
  end

  @impl true
  def teardown(%{ledger: ledger}) do
    if Process.alive?(ledger), do: Ledger.stop(ledger)
    :ok
  end

  @impl true
  def execute(%Open{currency: currency}, _assigns, _context) do
    {:ok, [%AccountOpened{id: "acct-1", currency: currency}]}
  end

  def execute(%Deposit{account_id: id, amount: amount}, _assigns, %{ledger: ledger}) do
    {:ok, [%Deposited{account_id: id, amount: amount, balance: Ledger.deposit(ledger, amount)}]}
  end

  def execute(%Withdraw{account_id: id, amount: amount}, _assigns, %{ledger: ledger}) do
    {:ok, [%Withdrawn{account_id: id, amount: amount, balance: Ledger.withdraw(ledger, amount)}]}
  end
end
