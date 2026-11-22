defmodule Corpus.Ledger.Events do
  @moduledoc "What happened against the ledger."

  defmodule AccountOpened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:currency, id: external()]
  end

  defmodule Deposited do
    @moduledoc false
    defstruct [:account_id, :amount, :balance]
  end

  defmodule Withdrawn do
    @moduledoc false
    defstruct [:account_id, :amount, :balance]
  end
end

defmodule Corpus.Ledger.Open do
  @moduledoc "Open the account. The system mints its id."
  use PropertyDamage.Command

  Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
  @emits [Corpus.Ledger.Events.AccountOpened]

  defstruct [:currency]

  @impl true
  def generator(overrides \\ %{}) do
    %{currency: StreamData.constant("USD")}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Ledger.Deposit do
  @moduledoc "Put 1 to 20 into the open account."
  use PropertyDamage.Command

  Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
  @emits [Corpus.Ledger.Events.Deposited]

  defstruct [:account_id, :amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{account_id: StreamData.constant(nil), amount: StreamData.integer(1..20)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Ledger.Withdraw do
  @moduledoc "Take money out of the open account."
  use PropertyDamage.Command

  Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
  @emits [Corpus.Ledger.Events.Withdrawn]

  defstruct [:account_id, :amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{account_id: StreamData.constant(nil), amount: StreamData.integer(1..20)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Ledger.World do
  @moduledoc """
  The sequence projection: the open account's id and the balance the model
  expects.
  """
  @behaviour PropertyDamage.Model.Projection

  alias Corpus.Ledger.Events.{AccountOpened, Deposited, Withdrawn}

  @impl true
  def init, do: %{account: nil, balance: 0}

  @impl true
  def apply(state, %AccountOpened{id: id}), do: %{state | account: id}
  def apply(state, %Deposited{amount: amount}), do: %{state | balance: state.balance + amount}
  def apply(state, %Withdrawn{amount: amount}), do: %{state | balance: state.balance - amount}
  def apply(state, _other), do: state
end

defmodule Corpus.Ledger.LedgerMatch do
  @moduledoc """
  Check projection: the balance the ledger reports equals the one rebuilt from
  the amounts the events carry.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Ledger.Events.{Deposited, Withdrawn}

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

defmodule Corpus.Ledger.Model do
  @moduledoc "Open one account, then deposit into it and withdraw from it."
  use PropertyDamage.Model

  alias Corpus.Ledger.{Deposit, LedgerMatch, Open, Withdraw, World}
  alias Corpus.Ledger.Events.{AccountOpened, Deposited, Withdrawn}

  @impl true
  def commands do
    [
      {Open, when: &is_nil(&1.account)},
      {Deposit, when: &(&1.account != nil), overrides: &%{account_id: &1.account}},
      {Withdraw,
       when: &(&1.account != nil and &1.balance > 0),
       overrides: fn state ->
         %{account_id: state.account, amount: StreamData.integer(1..state.balance)}
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: World

  @impl true
  def check_projections, do: [LedgerMatch]

  @impl true
  def simulator, do: __MODULE__

  @doc false
  def simulate(%Open{currency: currency}, _state), do: [%AccountOpened{currency: currency}]

  def simulate(%Deposit{account_id: id, amount: amount}, state),
    do: [%Deposited{account_id: id, amount: amount, balance: state.balance + amount}]

  def simulate(%Withdraw{account_id: id, amount: amount}, state),
    do: [%Withdrawn{account_id: id, amount: amount, balance: state.balance - amount}]
end

defmodule Corpus.Ledger.Adapter do
  @moduledoc "Runs the ledger commands against a `Corpus.Ledger` started with the entry's bug."
  use PropertyDamage.Adapter

  alias Corpus.Ledger
  alias Corpus.Ledger.Events.{AccountOpened, Deposited, Withdrawn}
  alias Corpus.Ledger.{Deposit, Open, Withdraw}

  @impl true
  def setup(config) do
    {:ok, ledger} = Ledger.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{ledger: ledger}}
  end

  @impl true
  def teardown(%{ledger: ledger}) do
    if Process.alive?(ledger), do: Ledger.stop(ledger)
    :ok
  end

  @impl true
  def execute(%Open{currency: currency}, _ctx, _runtime) do
    {:ok, [%AccountOpened{id: "acct-1", currency: currency}]}
  end

  def execute(%Deposit{account_id: id, amount: amount}, %{ledger: ledger}, _runtime) do
    {:ok, [%Deposited{account_id: id, amount: amount, balance: Ledger.deposit(ledger, amount)}]}
  end

  def execute(%Withdraw{account_id: id, amount: amount}, %{ledger: ledger}, _runtime) do
    {:ok, [%Withdrawn{account_id: id, amount: amount, balance: Ledger.withdraw(ledger, amount)}]}
  end
end
