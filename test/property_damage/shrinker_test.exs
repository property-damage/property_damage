defmodule PropertyDamage.ShrinkerTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Shrinker, Sequence}
  alias PropertyDamage.Shrinker.Config

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter}

  # ============================================================================
  # Failure Equivalence Tests
  # ============================================================================

  describe "failure_signature/1" do
    test "extracts signature from check_failed" do
      reason = {:check_failed, :balance_invariant, "Balance negative"}

      assert Shrinker.failure_signature(reason) == %{
               type: :check_failed,
               check_name: :balance_invariant
             }
    end

    test "extracts signature from idempotency_violation" do
      reason = {:idempotency_violation, %{command: %{}, events: []}}

      assert Shrinker.failure_signature(reason) == %{
               type: :idempotency_violation,
               check_name: nil
             }
    end

    test "extracts signature from linearization_failed" do
      reason = {:linearization_failed, "No valid ordering found"}

      assert Shrinker.failure_signature(reason) == %{
               type: :linearization_failed,
               check_name: nil
             }
    end

    test "unwraps branch_failure to get inner signature" do
      inner_reason = {:check_failed, :consistency, "Mismatch"}
      reason = {:branch_failure, 2, inner_reason}

      assert Shrinker.failure_signature(reason) == %{
               type: :check_failed,
               check_name: :consistency
             }
    end

    test "extracts signature from adapter_error" do
      reason = {:adapter_error, :connection_refused}

      assert Shrinker.failure_signature(reason) == %{
               type: :adapter_error,
               check_name: nil
             }
    end

    test "extracts signature from ref_resolution_error" do
      reason = {:ref_resolution_error, :unknown_ref}

      assert Shrinker.failure_signature(reason) == %{
               type: :ref_resolution_error,
               check_name: nil
             }
    end

    test "extracts signature from stutter_execution_failed" do
      reason = {:stutter_execution_failed, :timeout}

      assert Shrinker.failure_signature(reason) == %{
               type: :stutter_execution_failed,
               check_name: nil
             }
    end

    test "handles unknown tuple reasons" do
      reason = {:custom_error, :some_details, "extra"}

      assert Shrinker.failure_signature(reason) == %{
               type: :custom_error,
               check_name: nil
             }
    end

    test "handles non-tuple reasons" do
      assert Shrinker.failure_signature(:error) == %{type: :unknown, check_name: nil}
      assert Shrinker.failure_signature("string") == %{type: :unknown, check_name: nil}
      assert Shrinker.failure_signature(123) == %{type: :unknown, check_name: nil}
    end
  end

  describe "equivalent_failures?/2" do
    test "same check_failed with same check name are equivalent" do
      reason1 = {:check_failed, :balance, "Balance is -50"}
      reason2 = {:check_failed, :balance, "Balance is -100"}

      assert Shrinker.equivalent_failures?(reason1, reason2)
    end

    test "same check_failed with different check names are not equivalent" do
      reason1 = {:check_failed, :balance, "Error"}
      reason2 = {:check_failed, :consistency, "Error"}

      refute Shrinker.equivalent_failures?(reason1, reason2)
    end

    test "different failure types are not equivalent" do
      check = {:check_failed, :balance, "Error"}
      idempotency = {:idempotency_violation, %{}}
      adapter = {:adapter_error, :timeout}

      refute Shrinker.equivalent_failures?(check, idempotency)
      refute Shrinker.equivalent_failures?(check, adapter)
      refute Shrinker.equivalent_failures?(idempotency, adapter)
    end

    test "same non-check failure types are equivalent" do
      reason1 = {:idempotency_violation, %{first: 1}}
      reason2 = {:idempotency_violation, %{second: 2}}

      assert Shrinker.equivalent_failures?(reason1, reason2)
    end

    test "branch_failure is equivalent based on inner reason" do
      inner1 = {:check_failed, :balance, "Error 1"}
      inner2 = {:check_failed, :balance, "Error 2"}
      inner3 = {:check_failed, :other_check, "Error 3"}

      branch1 = {:branch_failure, 0, inner1}
      branch2 = {:branch_failure, 1, inner2}
      branch3 = {:branch_failure, 0, inner3}

      assert Shrinker.equivalent_failures?(branch1, branch2)
      refute Shrinker.equivalent_failures?(branch1, branch3)
    end
  end

  describe "shrinking with failure_reason" do
    alias PropertyDamage.Test.{MultiCheckModel, SimpleAdapter}

    test "preserves failure type when failure_reason is provided" do
      # This sequence triggers high_limit (> 200) not just low_limit (> 100)
      # Total: 250 (exceeds both limits, but fails high_limit first since both are :always)
      commands = [
        %CreateItem{name: "A", quantity: 150},
        %CreateItem{name: "B", quantity: 100}
      ]

      # The failure at index 1 is for high_limit (quantity 250 > 200)
      failure_reason = {:check_failed, :high_limit, "Quantity 250 exceeds high limit of 200"}

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          failure_reason: failure_reason,
          model: MultiCheckModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Since both commands together trigger high_limit (250 > 200),
      # and each alone would NOT trigger high_limit (150 and 100 are both <= 200),
      # the shrinker should preserve both commands
      shrunk_commands = Sequence.to_list(result.sequence)
      total = Enum.reduce(shrunk_commands, 0, fn cmd, acc -> acc + cmd.quantity end)

      # The shrunk total must still exceed 200 (to trigger high_limit)
      # If the shrinker accepted low_limit failures, it might shrink to just 150
      assert total > 200, "Shrunk sequence must still trigger high_limit (total: #{total})"
    end

    test "without failure_reason accepts any failure (backwards compatibility)" do
      # Same sequence that triggers high_limit
      commands = [
        %CreateItem{name: "A", quantity: 150},
        %CreateItem{name: "B", quantity: 100}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          # No failure_reason provided
          model: MultiCheckModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Without failure_reason, shrinker may shrink more aggressively
      # and accept a low_limit failure instead
      shrunk_commands = Sequence.to_list(result.sequence)
      total = Enum.reduce(shrunk_commands, 0, fn cmd, acc -> acc + cmd.quantity end)

      # The shrunk sequence still fails, but might only exceed 100 (not 200)
      assert total > 100, "Shrunk sequence must still fail some check"
    end
  end

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
