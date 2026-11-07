defmodule PropertyDamage.Sequence.ValidatorTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence
  alias PropertyDamage.Sequence.Validator

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.ExecutorModel

  describe "valid_sequence?/3" do
    test "returns true for empty sequence" do
      assert Validator.valid_sequence?(Sequence.linear([]), ExecutorModel)
    end

    test "returns true for valid single command" do
      commands = [%CreateItem{name: "Test", quantity: 5}]

      assert Validator.valid_sequence?(Sequence.linear(commands), ExecutorModel)
    end

    test "returns true for valid multi-command sequence" do
      commands = [
        %CreateItem{name: "First", quantity: 1},
        %CreateItem{name: "Second", quantity: 2},
        %CreateItem{name: "Third", quantity: 3}
      ]

      assert Validator.valid_sequence?(Sequence.linear(commands), ExecutorModel)
    end

    test "returns false when precondition fails" do
      # ViewItem requires items to exist; the item_ref value is irrelevant here.
      commands = [%ViewItem{item_ref: nil}]

      refute Validator.valid_sequence?(Sequence.linear(commands), ExecutorModel)
    end

    test "simulates state transitions" do
      # First create an item, then view it
      # This should pass because CreateItem.simulate creates the item state
      commands = [
        %CreateItem{name: "Test", quantity: 5},
        %CreateItem{name: "Another", quantity: 3}
      ]

      assert Validator.valid_sequence?(Sequence.linear(commands), ExecutorModel)
    end

    test "validates preconditions against simulated state" do
      # ViewItem after CreateItem should work because:
      # 1. CreateItem.simulate returns ItemCreated event
      # 2. ModelState.apply handles ItemCreated by adding to items map
      # 3. ViewItem.precondition checks if items map is non-empty
      # The item_ref value is irrelevant to the precondition.

      commands = [
        %CreateItem{name: "Test", quantity: 5},
        %ViewItem{item_ref: nil}
      ]

      # This should pass because CreateItem.simulate populates state
      assert Validator.valid_sequence?(Sequence.linear(commands), ExecutorModel)
    end
  end

  defmodule IdKeyedFixtures do
    # State keyed by an id the system mints, with a command that needs two ids.
    defmodule Created do
      import PropertyDamage, only: [external: 0]
      defstruct id: external()
    end

    defmodule Create do
      @behaviour PropertyDamage.Command
      defstruct []

      @impl true
      def generator(_overrides), do: StreamData.constant(%{})
    end

    defmodule Pair do
      @behaviour PropertyDamage.Command
      defstruct []

      @impl true
      def generator(_overrides), do: StreamData.constant(%{})
    end

    defmodule Ids do
      @behaviour PropertyDamage.Model.Projection

      @impl true
      def init, do: %{ids: %{}}

      @impl true
      def apply(state, %Created{id: id}), do: put_in(state.ids[id], true)
      def apply(state, _other), do: state
    end

    defmodule Model do
      @behaviour PropertyDamage.Model.Simulator
      use PropertyDamage.Model

      @impl PropertyDamage.Model
      def commands do
        [Create, {Pair, when: fn state -> map_size(state.ids) >= 2 end}]
      end

      @impl PropertyDamage.Model
      def command_sequence_projection, do: Ids

      @impl PropertyDamage.Model
      def simulator, do: __MODULE__

      @impl PropertyDamage.Model.Simulator
      def simulate(%Create{}, _state), do: [%Created{}]
      def simulate(_command, _state), do: []
    end
  end

  describe "valid_sequence?/3 over a state keyed by minted ids" do
    test "accepts a generated sequence whose command needs two distinct ids" do
      sequence =
        1..40
        |> Enum.map(fn seed ->
          IdKeyedFixtures.Model
          |> PropertyDamage.Generator.generate_sequence(max_commands: 8)
          |> PropertyDamage.Generator.generate_value(seed)
        end)
        |> Enum.find(fn sequence ->
          Enum.any?(sequence.prefix, &match?(%IdKeyedFixtures.Pair{}, &1))
        end)

      assert sequence, "no drawn sequence contains the dependent command"

      assert Validator.valid_sequence?(sequence, IdKeyedFixtures.Model)
    end
  end
end
