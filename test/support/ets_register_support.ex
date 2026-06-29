defmodule PropertyDamage.Test.EtsRegister do
  @moduledoc """
  Shared SUT for the Phase 6c parallel + linearization bench (zero infra).

  A real ETS-backed counter register: increments are atomic
  (`:ets.update_counter/3`), so a correctly-implemented register is always
  linearizable. This is the canonical linearizability example (each increment
  observes `from -> to = from + 1`), and a richer model than 6a's key/value
  store: the value-carrying `from/to` events let the linearization checker
  refute lost updates on EVENTS alone, independent of any assertion.

  The bench drives this through PD's branching generation. Against the faithful
  `CorrectAdapter` no ordering is ever refuted (locks in the linearization
  soundness fix on a real concurrent data structure). The seeded
  `StaleSnapshotAdapter` reports each increment from a snapshot it never
  refreshes, so two parallel increments both claim `from: 0`: a lost update
  that no serialization explains, which PD detects and shrinks to the minimal
  two-increment race.
  """

  @doc "Atomic increment. Returns {from, to}."
  def increment(table) do
    to = :ets.update_counter(table, :count, 1)
    {to - 1, to}
  end

  @doc "Read the current counter value."
  def read(table), do: :ets.lookup_element(table, :count, 2)

  @doc "Create a fresh counter table seeded at 0. Returns the table id."
  def new do
    table = :ets.new(:pd_ets_register, [:set, :public])
    :ets.insert(table, {:count, 0})
    table
  end
end

defmodule PropertyDamage.Test.EtsRegister.Commands.Increment do
  @moduledoc "Atomically increment the register."
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end

defmodule PropertyDamage.Test.EtsRegister.Commands.ReadValue do
  @moduledoc "Read the register; the model asserts the value matches expectation."
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def read_only?, do: true

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end

defmodule PropertyDamage.Test.EtsRegister.Events do
  @moduledoc "Events describing what happened against the register."

  defmodule Incremented do
    @moduledoc false
    defstruct [:from, :to]
  end

  defmodule ValueRead do
    @moduledoc false
    defstruct [:value]
  end
end

defmodule PropertyDamage.Test.EtsRegister.Projection do
  @moduledoc """
  Tracks the expected counter value and asserts every observed read matches it.
  """
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Test.EtsRegister.Commands.ReadValue
  alias PropertyDamage.Test.EtsRegister.Events.{Incremented, ValueRead}

  @impl true
  def init, do: %{count: 0, last_read: nil}

  @impl true
  def apply(state, %Incremented{to: to}), do: %{state | count: to}
  def apply(state, %ValueRead{value: value}), do: %{state | last_read: value}
  def apply(state, _event), do: state

  @trigger every: ReadValue
  def assert_value_consistent(state, _command) do
    if state.last_read != state.count do
      PropertyDamage.fail!(
        "Read returned #{inspect(state.last_read)}, model expects #{inspect(state.count)}",
        actual: state.last_read,
        expected: state.count
      )
    end
  end
end

defmodule PropertyDamage.Test.EtsRegister.Simulator do
  @moduledoc "Predicts events during generation, before any table exists."
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.EtsRegister.Commands.{Increment, ReadValue}
  alias PropertyDamage.Test.EtsRegister.Events.{Incremented, ValueRead}

  @impl true
  def simulate(%Increment{}, state) do
    [%Incremented{from: state.count, to: state.count + 1}]
  end

  def simulate(%ReadValue{}, state) do
    [%ValueRead{value: state.count}]
  end

  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Test.EtsRegister.Model do
  @moduledoc "Ties the register commands and the consistency projection together."
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.EtsRegister.Commands.{Increment, ReadValue}

  @impl true
  def commands do
    [
      {Increment, weight: 5},
      {ReadValue, weight: 3}
    ]
  end

  @impl true
  def command_sequence_projection, do: PropertyDamage.Test.EtsRegister.Projection

  @impl true
  def assertion_projections, do: [PropertyDamage.Test.EtsRegister.Projection]

  @impl true
  def simulator, do: PropertyDamage.Test.EtsRegister.Simulator
end

defmodule PropertyDamage.Test.EtsRegister.CorrectAdapter do
  @moduledoc "Faithfully drives the atomic ETS register. Always linearizable."
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.EtsRegister
  alias PropertyDamage.Test.EtsRegister.Commands.{Increment, ReadValue}
  alias PropertyDamage.Test.EtsRegister.Events.{Incremented, ValueRead}

  @impl true
  def setup(_config) do
    {:ok, %{table: EtsRegister.new()}}
  end

  @impl true
  def teardown(%{table: table}) do
    if :ets.info(table) != :undefined, do: :ets.delete(table)
    :ok
  end

  @impl true
  def execute(%Increment{}, %{table: table}, _runtime) do
    {from, to} = EtsRegister.increment(table)
    {:ok, [%Incremented{from: from, to: to}]}
  end

  def execute(%ReadValue{}, %{table: table}, _runtime) do
    {:ok, [%ValueRead{value: EtsRegister.read(table)}]}
  end
end
