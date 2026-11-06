defmodule PropertyDamage.Test.Gauntlet do
  @moduledoc """
  A small ledger system with a seeded defect, for tests that run a real failing
  campaign and then analyze its report.

  One account is opened (the SUT mints its id), money is deposited into it and
  withdrawn from it. `Deposit` and `Withdraw` consume the account id the
  `Open` command's event minted, so a failing sequence has a real dependency
  chain. A check asserts the balance the SUT reports matches the ledger the
  model rebuilds from the events.

  The adapter's `bug` config picks the seeded defect:

    * `:off` is the correct SUT; every run passes.
    * `{:double_debit_from, n}` debits twice the amount on a withdrawal of `n`
      or more, so the reported balance drifts from the ledger.
    * `:crash` raises on every withdrawal.

  The check compares the SUT's balance with the ledger, not with zero, so a
  shrunk sequence fails only when the defect fires.
  """

  @doc "Runs the campaign of `model` against the adapter with `bug`, with a fixed seed."
  @spec run(module(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(model, bug, opts \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: [{PropertyDamage.Test.Gauntlet.Adapter, config: %{bug: bug}}],
          seed: 7,
          max_runs: 60,
          max_commands: 8,
          verbose: false
        ],
        opts
      )
    )
  end

  defmodule Events.AccountOpened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:currency, id: external()]
  end

  defmodule Events.Deposited do
    @moduledoc false
    defstruct [:account_id, :amount, :balance]
  end

  defmodule Events.Withdrawn do
    @moduledoc false
    defstruct [:account_id, :amount, :balance]
  end

  defmodule Commands.Open do
    @moduledoc false
    use PropertyDamage.Command

    Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
    @emits [PropertyDamage.Test.Gauntlet.Events.AccountOpened]

    defstruct [:currency]

    @impl true
    def generator(overrides \\ %{}) do
      %{currency: StreamData.constant("USD")}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Commands.Deposit do
    @moduledoc false
    use PropertyDamage.Command

    Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
    @emits [PropertyDamage.Test.Gauntlet.Events.Deposited]

    defstruct [:account_id, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{account_id: StreamData.constant(nil), amount: StreamData.integer(1..20)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Commands.Withdraw do
    @moduledoc false
    use PropertyDamage.Command

    Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
    @emits [PropertyDamage.Test.Gauntlet.Events.Withdrawn]

    defstruct [:account_id, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{account_id: StreamData.constant(nil), amount: StreamData.integer(1..20)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule World do
    @moduledoc false
    # The sequence projection: the open account's id and the balance the model
    # expects.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.Gauntlet.Events.{AccountOpened, Deposited, Withdrawn}

    @impl true
    def init, do: %{account: nil, balance: 0}

    @impl true
    def apply(state, %AccountOpened{id: id}), do: %{state | account: id}
    def apply(state, %Deposited{amount: amount}), do: %{state | balance: state.balance + amount}
    def apply(state, %Withdrawn{amount: amount}), do: %{state | balance: state.balance - amount}
    def apply(state, _other), do: state
  end

  defmodule LedgerMatch do
    @moduledoc false
    # Check projection: the balance the SUT reports equals the ledger rebuilt
    # from the amounts the events carry.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.Gauntlet.Events.{Deposited, Withdrawn}

    @impl true
    def init, do: %{ledger: 0, reported: 0}

    @impl true
    def apply(state, %Deposited{amount: amount, balance: balance}),
      do: %{state | ledger: state.ledger + amount, reported: balance}

    def apply(state, %Withdrawn{amount: amount, balance: balance}),
      do: %{state | ledger: state.ledger - amount, reported: balance}

    def apply(state, _other), do: state

    # One detail key: the message renders the details as a map, and the order of
    # several keys changed from one test order to another.
    @check every: 1
    def assert_balance_matches_ledger(state, _cmd_or_event) do
      state.reported == state.ledger or
        PropertyDamage.fail!("Reported balance differs from the ledger",
          drift: state.reported - state.ledger
        )
    end
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    alias PropertyDamage.Test.Gauntlet.{Commands, LedgerMatch, World}
    alias PropertyDamage.Test.Gauntlet.Events.{AccountOpened, Deposited, Withdrawn}

    @impl true
    def commands do
      [
        {Commands.Open, when: &is_nil(&1.account)},
        {Commands.Deposit, when: &(&1.account != nil), overrides: &%{account_id: &1.account}},
        {Commands.Withdraw,
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
    def simulate(%Commands.Open{currency: currency}, _state),
      do: [%AccountOpened{currency: currency}]

    def simulate(%Commands.Deposit{account_id: id, amount: amount}, state),
      do: [%Deposited{account_id: id, amount: amount, balance: state.balance + amount}]

    def simulate(%Commands.Withdraw{account_id: id, amount: amount}, state),
      do: [%Withdrawn{account_id: id, amount: amount, balance: state.balance - amount}]
  end

  defmodule UncheckedModel do
    @moduledoc false
    # The same system as `Model`, with no check projections.
    use PropertyDamage.Model

    @impl true
    defdelegate commands, to: PropertyDamage.Test.Gauntlet.Model

    @impl true
    defdelegate command_sequence_projection, to: PropertyDamage.Test.Gauntlet.Model

    @impl true
    def check_projections, do: []

    @impl true
    defdelegate simulator, to: PropertyDamage.Test.Gauntlet.Model
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Gauntlet.Commands
    alias PropertyDamage.Test.Gauntlet.Events.{AccountOpened, Deposited, Withdrawn}

    @impl true
    def setup(config) do
      {:ok, store} = Agent.start_link(fn -> 0 end)
      {:ok, Map.put(Map.new(config), :store, store)}
    end

    @impl true
    def teardown(%{store: store}) do
      Agent.stop(store)
      :ok
    end

    @impl true
    def execute(%Commands.Open{currency: currency}, _ctx, _runtime) do
      {:ok, [%AccountOpened{id: "acct-1", currency: currency}]}
    end

    def execute(%Commands.Deposit{account_id: id, amount: amount}, ctx, _runtime) do
      balance = Agent.get_and_update(ctx.store, fn b -> {b + amount, b + amount} end)
      {:ok, [%Deposited{account_id: id, amount: amount, balance: balance}]}
    end

    def execute(%Commands.Withdraw{account_id: id, amount: amount}, ctx, _runtime) do
      debit = debit(Map.get(ctx, :bug, :off), amount)
      balance = Agent.get_and_update(ctx.store, fn b -> {b - debit, b - debit} end)
      {:ok, [%Withdrawn{account_id: id, amount: amount, balance: balance}]}
    end

    defp debit(:crash, _amount), do: raise("ledger unavailable")
    defp debit({:double_debit_from, n}, amount) when amount >= n, do: 2 * amount
    defp debit(_bug, amount), do: amount
  end
end
