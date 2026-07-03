defmodule PropertyDamage.Test.FI.Events do
  @moduledoc false
  # Events for the fix-verification fixture.

  defmodule Deposited do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Overdrawn do
    @moduledoc false
    defstruct [:amount]
  end
end

defmodule PropertyDamage.Test.FI.Op do
  @moduledoc """
  Single command for the fix-verification fixture. Carries an `amount` drawn
  deterministically from the run seed; the adapter's seeded-bug switch keys on
  that amount so a given seed deterministically passes or fails.
  """
  use PropertyDamage.Command, observables: [PropertyDamage.Test.FI.Events.Deposited]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..100)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.FI.State do
  @moduledoc false
  # command_sequence_projection: Op has no precondition so this stays trivial.
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _), do: state
end

defmodule PropertyDamage.Test.FI.Balance do
  @moduledoc false
  # Assertion projection: balance must never go negative. A normal Op deposits a
  # positive amount (safe); a buggy Op overdraws, driving the balance negative
  # and firing the invariant.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Test.FI.Events.{Deposited, Overdrawn}

  @impl true
  def init, do: %{balance: 0}

  @impl true
  def apply(state, %Deposited{amount: amount}) do
    update_in(state, [:balance], &(&1 + amount))
  end

  def apply(state, %Overdrawn{amount: amount}) do
    update_in(state, [:balance], &(&1 - amount))
  end

  def apply(state, _), do: state

  @trigger every: 1
  def assert_balance_non_negative(state, _cmd_or_event) do
    unless state.balance >= 0 do
      PropertyDamage.fail!("Balance is negative", balance: state.balance)
    end
  end
end

defmodule PropertyDamage.Test.FI.Model do
  @moduledoc """
  Fix-verification fixture model. Runs exactly one `Op` per sequence (terminates
  after the first command) so each `PropertyDamage.run` call exercises a single,
  seed-determined command against the seeded-bug adapter.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.FI.{Balance, State}
  alias PropertyDamage.Test.FI.Events.Deposited
  alias PropertyDamage.Test.FI.Op

  @impl true
  def commands, do: [Op]

  @impl true
  def command_sequence_projection, do: State

  @impl true
  def assertion_projections, do: [Balance]

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%Op{amount: amount}, _state) do
    [%Deposited{amount: amount}]
  end

  @impl true
  def terminate?(_state, %Op{}, _events), do: true
end

defmodule PropertyDamage.Test.FI.Adapter do
  @moduledoc """
  Seeded-bug adapter for the fix-verification fixture.

  The bug switch lives in `adapter_config[:bug]`:

    * `:off` — never overdraws (the "fixed" SUT); every run passes.
    * `:always` — always overdraws (the unfixed SUT); every run fails.
    * `{:overdraw_when_amount_lte, t}` — overdraws only when the seed-derived
      `amount` is `<= t`. Because `amount` is a deterministic function of the run
      seed, this makes each seed deterministically pass or fail, which is the
      intermittent switch used to drive `:partially_fixed`/`:flaky` outcomes.
  """
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.FI.Events.{Deposited, Overdrawn}
  alias PropertyDamage.Test.FI.Op

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%Op{amount: amount}, config, _runtime) do
    if buggy?(Map.get(config, :bug, :off), amount) do
      {:ok, [%Overdrawn{amount: 1000}]}
    else
      {:ok, [%Deposited{amount: amount}]}
    end
  end

  defp buggy?(:off, _amount), do: false
  defp buggy?(:always, _amount), do: true
  defp buggy?({:overdraw_when_amount_lte, t}, amount), do: amount <= t
  defp buggy?(_other, _amount), do: false
end
