defmodule PropertyDamage.ShrinkerTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Shrinker, Sequence}
  alias PropertyDamage.Shrinker.Config

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter}

  describe "shrink/2" do
    test "drops unexecuted commands" do
      # Create a sequence where failure happens at index 1
      # Commands after index 1 should be dropped
      commands = [
        %CreateItem{name: "First", quantity: 50},
        # Fails at index 1
        %CreateItem{name: "Failing", quantity: 101},
        %CreateItem{name: "Never Executed", quantity: 10},
        %CreateItem{name: "Also Never", quantity: 20}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should only have commands up to and including the failure
      shrunk_commands = Sequence.to_list(result.sequence)
      assert length(shrunk_commands) <= 2
    end

    test "removes unnecessary commands" do
      # Create a sequence where only the last command causes failure
      commands = [
        # Can be removed
        %CreateItem{name: "A", quantity: 10},
        # Can be removed
        %CreateItem{name: "B", quantity: 20},
        # Causes failure
        %CreateItem{name: "Failing", quantity: 101}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 2,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should shrink to just the failing command
      shrunk_commands = Sequence.to_list(result.sequence)
      assert length(shrunk_commands) == 1
      assert hd(shrunk_commands).quantity == 101
    end

    test "preserves failure reproduction" do
      commands = [
        %CreateItem{name: "Small", quantity: 50},
        # Together they exceed 100
        %CreateItem{name: "Big", quantity: 60}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # The shrunk sequence should still fail
      # Since removing either command would make it pass (50 or 60 alone < 100)
      # Both commands should remain
      shrunk_commands = Sequence.to_list(result.sequence)
      assert length(shrunk_commands) == 2
    end

    test "returns iterations count" do
      commands = [%CreateItem{name: "Failing", quantity: 101}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter
        )

      assert is_integer(result.iterations)
      assert result.iterations >= 0
    end

    test "returns time in milliseconds" do
      commands = [%CreateItem{name: "Failing", quantity: 101}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter
        )

      assert is_integer(result.time_ms)
      assert result.time_ms >= 0
    end

    test "returns a Sequence struct" do
      commands = [%CreateItem{name: "Failing", quantity: 101}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter
        )

      assert %Sequence{} = result.sequence
    end
  end

  describe "argument shrinking" do
    test "attempts to shrink integers" do
      # Use a value where halving (400 -> 200) still exceeds threshold (100)
      commands = [%CreateItem{name: "X", quantity: 400}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: true)
        )

      # Should shrink quantity from 400 -> 200 (still > 100, so fails)
      shrunk_commands = Sequence.to_list(result.sequence)
      shrunk_qty = hd(shrunk_commands).quantity
      assert shrunk_qty > 100
      assert shrunk_qty <= 400
    end

    test "shrinks strings when failure doesn't depend on string value" do
      # The failure depends on quantity, not name, so name can shrink freely
      commands = [%CreateItem{name: "VeryLongNameHere", quantity: 400}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: true)
        )

      shrunk_commands = Sequence.to_list(result.sequence)
      shrunk_name = hd(shrunk_commands).name
      # Name should shrink since it doesn't affect the failure
      assert String.length(shrunk_name) < String.length("VeryLongNameHere")
    end

    test "preserves command struct type" do
      commands = [%CreateItem{name: "Test", quantity: 101}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: true)
        )

      # Verify command type is preserved
      shrunk_commands = Sequence.to_list(result.sequence)
      assert hd(shrunk_commands).__struct__ == CreateItem
    end

    test "can be disabled via config" do
      commands = [%CreateItem{name: "LongName", quantity: 200}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # With shrinking disabled, values should remain unchanged
      shrunk_commands = Sequence.to_list(result.sequence)
      assert hd(shrunk_commands).quantity == 200
      assert hd(shrunk_commands).name == "LongName"
    end
  end

  describe "limits" do
    test "respects max_iterations" do
      commands = [
        %CreateItem{name: "A", quantity: 30},
        %CreateItem{name: "B", quantity: 30},
        %CreateItem{name: "C", quantity: 30},
        # Total: 120 > 100
        %CreateItem{name: "D", quantity: 30}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 3,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(max_iterations: 5, shrink_arguments: false)
        )

      assert result.iterations <= 5
    end

    test "respects max_time_ms" do
      commands = [%CreateItem{name: "Failing", quantity: 101}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(max_time_ms: 100)
        )

      # Some buffer for test overhead
      assert result.time_ms < 200
    end
  end
end
