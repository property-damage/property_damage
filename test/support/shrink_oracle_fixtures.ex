defmodule PropertyDamage.Test.ShrinkOracle do
  @moduledoc false
  # Pure fixtures for driving the shrinker with an in-memory oracle: commands,
  # a projection, two models (one with a `when:` precondition) and a target
  # adapter that is never called. Nothing here starts a process.

  defmodule Opened do
    @moduledoc false
    defstruct [:account]
  end

  defmodule Deposited do
    @moduledoc false
    defstruct [:account, :amount]
  end

  defmodule Withdrawn do
    @moduledoc false
    defstruct [:account, :amount]
  end

  defmodule Audited do
    @moduledoc false
    defstruct [:account]
  end

  defmodule Open do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.fixed_map(account: :alice)
  end

  defmodule Deposit do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{account: StreamData.member_of([:alice, :bob]), amount: StreamData.integer(1..50)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Withdraw do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{account: StreamData.member_of([:alice, :bob]), amount: StreamData.integer(1..50)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Audit do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account]

    @impl true
    def generator(overrides \\ %{}) do
      %{account: StreamData.member_of([:alice, :bob])}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Close do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule State do
    @moduledoc false
    # What the models read: whether an audit ran.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ShrinkOracle, as: O

    @impl true
    def init, do: %{audited: false}

    @impl true
    def apply(state, %O.Audited{}), do: %{state | audited: true}
    def apply(state, _event), do: state
  end

  defmodule Simulate do
    @moduledoc false
    alias PropertyDamage.Test.ShrinkOracle, as: O

    def simulate(%O.Open{account: account}, _state), do: [%O.Opened{account: account}]

    def simulate(%O.Deposit{account: account, amount: amount}, _state),
      do: [%O.Deposited{account: account, amount: amount}]

    def simulate(%O.Withdraw{account: account, amount: amount}, _state),
      do: [%O.Withdrawn{account: account, amount: amount}]

    def simulate(%O.Audit{account: account}, _state), do: [%O.Audited{account: account}]
    def simulate(%O.Close{}, _state), do: []
  end

  defmodule Model do
    @moduledoc false
    # Any order of deposits, withdrawals and audits is valid.
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    alias PropertyDamage.Test.ShrinkOracle, as: O

    @impl true
    def commands, do: [O.Deposit, O.Withdraw, O.Audit]

    @impl true
    def command_sequence_projection, do: O.State

    @impl true
    def setup_each, do: [O.Open]

    @impl true
    def teardown_each, do: [O.Close]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    defdelegate simulate(command, state), to: O.Simulate
  end

  defmodule GatedModel do
    @moduledoc false
    # A withdrawal is valid only after an audit ran.
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    alias PropertyDamage.Test.ShrinkOracle, as: O

    @impl true
    def commands do
      [O.Deposit, O.Audit, {O.Withdraw, when: fn state -> state.audited end}]
    end

    @impl true
    def command_sequence_projection, do: O.State

    @impl true
    def setup_each, do: [O.Open]

    @impl true
    def teardown_each, do: [O.Close]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    defdelegate simulate(command, state), to: O.Simulate
  end

  defmodule NeverCalledAdapter do
    @moduledoc false
    # The oracle stands in for the adapter, so a shrink that reaches this
    # module ran a candidate itself.
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:error, :adapter_must_not_run}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(_command, _context, _runtime), do: {:error, :adapter_must_not_run}
  end

  @doc "The one target every shrink here names; its adapter is never called."
  def targets,
    do: [
      %PropertyDamage.Target{adapter: NeverCalledAdapter, config: %{}, name: "ledger", index: 0}
    ]

  @doc "The failure the original run reported."
  def failure, do: PropertyDamage.Failure.check_failed(:no_overdraft, "balance below zero")

  @doc "The signature of `failure/0` in target 0."
  def signature, do: PropertyDamage.Failure.signature(failure(), 0)

  @doc "A sequence of `commands` whose setup commands are `setup`."
  def sequence(commands, setup \\ [%Open{account: :alice}]) do
    commands |> PropertyDamage.Sequence.linear() |> Map.put(:setup, setup)
  end

  # Predicates over a candidate's roots. Each returns the index of the root at
  # which the candidate fails, or nil when it passes.

  @doc "Index of the first withdrawal that follows a deposit to the same account."
  def withdraw_after_deposit(commands, min_amount \\ 0) do
    commands
    |> Enum.with_index()
    |> Enum.find_value(fn
      {%Withdraw{account: account, amount: amount}, index} when amount >= min_amount ->
        if Enum.any?(Enum.take(commands, index), &match?(%Deposit{account: ^account}, &1)),
          do: index

      _other ->
        nil
    end)
  end

  @doc "Index of the first root at which withdrawals exceed deposits."
  def overdraft(commands) do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn
      {%Deposit{amount: amount}, _index}, balance -> {:cont, balance + amount}
      {%Withdraw{amount: amount}, index}, balance when amount > balance -> {:halt, {:at, index}}
      {%Withdraw{amount: amount}, _index}, balance -> {:cont, balance - amount}
      {_other, _index}, balance -> {:cont, balance}
    end)
    |> case do
      {:at, index} -> index
      _balance -> nil
    end
  end
end
