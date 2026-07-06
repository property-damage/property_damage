defmodule PropertyDamage.ShrinkerTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Sequence, Shrinker}
  alias PropertyDamage.Shrinker.Config

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter}

  # ============================================================================
  # Failure Equivalence Tests
  # ============================================================================

  describe "failure_signature/1" do
    test "extracts {kind, name} from an assertion failure" do
      reason = Failure.assertion_failed(:balance_invariant, "Balance negative")
      assert Shrinker.failure_signature(reason) == {:assertion_failed, :balance_invariant}
    end

    test "extracts signature from idempotency_violation" do
      reason = Failure.idempotency_violation(%{command: %{}, events: []})
      assert Shrinker.failure_signature(reason) == {:idempotency_violation, nil}
    end

    test "extracts signature from linearization" do
      reason = Failure.linearization("No valid ordering found")
      assert Shrinker.failure_signature(reason) == {:linearization, nil}
    end

    test "a branch failure carries the inner kind + name (branch_id not in the signature)" do
      inner = Failure.assertion_failed(:consistency, "Mismatch")
      reason = Failure.in_branch(inner, 2)
      assert Shrinker.failure_signature(reason) == {:assertion_failed, :consistency}
    end

    test "extracts signature from adapter_error" do
      reason = Failure.adapter_error(:connection_refused)
      assert Shrinker.failure_signature(reason) == {:adapter_error, nil}
    end

    test "extracts signature from placeholder_resolution" do
      reason = Failure.placeholder_resolution(:unknown_placeholder)
      assert Shrinker.failure_signature(reason) == {:placeholder_resolution, nil}
    end

    test "extracts signature from stutter_execution_failed" do
      reason = Failure.stutter_execution_failed(:timeout)
      assert Shrinker.failure_signature(reason) == {:stutter_execution_failed, nil}
    end

    test "handles non-Failure reasons" do
      assert Shrinker.failure_signature(:error) == {:unknown, nil}
      assert Shrinker.failure_signature("string") == {:unknown, nil}
      assert Shrinker.failure_signature(123) == {:unknown, nil}
    end

    test "named assertion failures carry the assertion name (DR-025)" do
      reason = Failure.assertion_failed(:counter_never_exceeds, {%RuntimeError{}, []})
      assert Shrinker.failure_signature(reason) == {:assertion_failed, :counter_never_exceeds}
    end

    test "a poll_timeout and an assertion failure of the SAME name are NOT equivalent" do
      # Load-bearing (DR-041 D4): both name themselves :ledger_settles, but they
      # are different bugs. Keying the signature on the globally-unique KIND (not
      # the coarser class) keeps them distinct; a class-based signature
      # ({:assertion, :ledger_settles} for both) would merge them and let the
      # shrinker swap a poll-timeout for an invariant violation of the same name.
      name = :ledger_settles

      poll =
        Failure.poll_timeout(%{
          triggered_by: %{assertion_name: name},
          elapsed_ms: 10,
          poll_count: 1
        })

      assertion = Failure.assertion_failed(name, {%RuntimeError{}, []})

      assert Shrinker.failure_signature(poll) == {:poll_timeout, name}
      assert Shrinker.failure_signature(assertion) == {:assertion_failed, name}
      refute Shrinker.equivalent_failures?(poll, assertion)
    end
  end

  describe "equivalent_failures?/2" do
    test "same assertion failure with same name are equivalent" do
      reason1 = Failure.assertion_failed(:balance, "Balance is -50")
      reason2 = Failure.assertion_failed(:balance, "Balance is -100")
      assert Shrinker.equivalent_failures?(reason1, reason2)
    end

    test "same assertion failure with different names are not equivalent" do
      reason1 = Failure.assertion_failed(:balance, "Error")
      reason2 = Failure.assertion_failed(:consistency, "Error")
      refute Shrinker.equivalent_failures?(reason1, reason2)
    end

    test "distinct assertion failures are not equivalent, same one is (DR-025)" do
      a = Failure.assertion_failed(:counter_never_exceeds, {%RuntimeError{}, []})
      b = Failure.assertion_failed(:other_invariant, {%RuntimeError{}, []})
      # An async-observed failure and a teardown failure of the SAME assertion
      # carry the same name, so they remain equivalent for shrinking.
      a_again =
        Failure.assertion_failed(:counter_never_exceeds, {%ArgumentError{}, [{:mod, :f, 1, []}]})

      refute Shrinker.equivalent_failures?(a, b)
      assert Shrinker.equivalent_failures?(a, a_again)
    end

    test "different failure kinds are not equivalent" do
      check = Failure.assertion_failed(:balance, "Error")
      idempotency = Failure.idempotency_violation(%{})
      adapter = Failure.adapter_error(:timeout)

      refute Shrinker.equivalent_failures?(check, idempotency)
      refute Shrinker.equivalent_failures?(check, adapter)
      refute Shrinker.equivalent_failures?(idempotency, adapter)
    end

    test "same non-assertion failure kinds are equivalent" do
      reason1 = Failure.idempotency_violation(%{first: 1})
      reason2 = Failure.idempotency_violation(%{second: 2})
      assert Shrinker.equivalent_failures?(reason1, reason2)
    end

    test "branch failures are equivalent based on the inner kind + name" do
      branch1 = Failure.in_branch(Failure.assertion_failed(:balance, "Error 1"), 0)
      branch2 = Failure.in_branch(Failure.assertion_failed(:balance, "Error 2"), 1)
      branch3 = Failure.in_branch(Failure.assertion_failed(:other_check, "Error 3"), 0)

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
      failure_reason =
        Failure.assertion_failed(:high_limit, "Quantity 250 exceeds high limit of 200")

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

    test "shrinks a multi-byte-UTF8 string value (consistent units)" do
      # Every character is 2 bytes, so byte_size is twice the codepoint length.
      # Halving with String.slice/3 by a byte-length divisor slices that many
      # CODEPOINTS, which for a multi-byte string is >= the codepoint count, so it
      # returns the whole string and the value never shrinks. The failure depends
      # only on quantity, so the name is free to shrink toward empty.
      name = String.duplicate("é", 8)
      assert byte_size(name) == 16

      commands = [%CreateItem{name: name, quantity: 400}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: true)
        )

      shrunk_name = hd(Sequence.to_list(result.sequence)).name

      # A byte-consistent halving makes real progress; the buggy codepoint/byte
      # mismatch leaves the value at its full size.
      assert byte_size(shrunk_name) < byte_size(name)
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

      # max_time_ms is wall-clock, so under parallel-suite scheduling load
      # the measured time can exceed the budget by a wide margin. Generous
      # headroom keeps this non-flaky; the real fix is the planned switch to
      # an iteration budget (tracked in the fix checklist).
      assert result.time_ms < 2_000
    end
  end

  # ============================================================================
  # Branching Sequence Shrinking Tests
  # ============================================================================

  describe "shrink/2 with branching sequences" do
    test "shrinks branching sequence to minimal reproduction" do
      # Create a branching sequence where only the prefix causes failure
      seq =
        Sequence.branching(
          # This alone causes failure (> 100)
          [%CreateItem{name: "Prefix", quantity: 101}],
          [
            [%CreateItem{name: "BranchA", quantity: 10}],
            [%CreateItem{name: "BranchB", quantity: 20}]
          ],
          [%CreateItem{name: "Suffix", quantity: 5}]
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should shrink to just the failing command
      shrunk_count = Sequence.command_count(result.sequence)
      assert shrunk_count <= 4
    end

    test "converts to linear when race not required" do
      # Create a branching sequence where the failure doesn't depend on parallelism
      # Total quantity: 60 + 50 = 110 > 100, fails regardless of order
      seq =
        Sequence.branching(
          [],
          [
            [%CreateItem{name: "BranchA", quantity: 60}],
            [%CreateItem{name: "BranchB", quantity: 50}]
          ],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 1,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should convert to linear sequence since race is not needed
      assert Sequence.linear?(result.sequence)
    end

    test "converted-linear shrink truncates at the linear failure index, not the branch-relative one" do
      # The failure lives in the SECOND branch, after a non-empty first branch.
      # When flattened to prefix ++ branch0 ++ branch1, the failing command "B"
      # sits at linear index 2, but its branch-relative coordinate
      # (branch_start_index + position = 0 + 0) is 0. Passing the branch-relative
      # index to the linear shrink truncates to [A1] (which does not fail), so the
      # truncation is rejected and the full flattened sequence is left to the
      # one-by-one fixpoint. Under a tight iteration budget that fixpoint cannot
      # clear the long filler tail, so the reproduction stays non-minimal.
      #
      # Cumulative-quantity check fails at > 100: A1(10) + A2(10) + B(85) = 105.
      # The only 3-command subset that exceeds 100 is [A1, A2, B], so a correct
      # truncation at linear index 2 reaches the minimum in a single iteration.
      tail = for n <- 1..8, do: %CreateItem{name: "T#{n}", quantity: 1}

      seq =
        Sequence.branching(
          [],
          [
            [%CreateItem{name: "A1", quantity: 10}, %CreateItem{name: "A2", quantity: 10}],
            [%CreateItem{name: "B", quantity: 85} | tail]
          ],
          []
        )

      result =
        Shrinker.shrink(seq,
          # Branch-relative index the executor would mint for B (branch1, pos 0).
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config:
            Config.new(
              shrink_arguments: false,
              # Force the one-by-one linear path (no hierarchical batch removal).
              granularity_threshold: 100,
              # Enough for a single truncation + verifying the 3 survivors, but
              # far too few to delete an 8-command tail one command at a time.
              max_iterations: 8
            )
        )

      assert Sequence.command_count(result.sequence) == 3
    end

    test "preserves branching when needed for failure" do
      # This is a simpler test - the shrinker should not break the failure
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 50}],
          [
            # Total with prefix: 110 > 100
            [%CreateItem{name: "BranchA", quantity: 60}],
            [%CreateItem{name: "BranchB", quantity: 10}]
          ],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 1,
          failure_reason: Failure.assertion_failed(:quantity_limit, "exceeds limit"),
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Verify the shrunk sequence still has commands that total > 100
      shrunk_commands = Sequence.to_list(result.sequence)
      total = Enum.reduce(shrunk_commands, 0, fn cmd, acc -> acc + cmd.quantity end)
      assert total > 100, "Shrunk sequence must still fail (total: #{total})"
    end

    test "shrinks individual branch contents" do
      # Create a sequence with unnecessarily long branches
      seq =
        Sequence.branching(
          [],
          [
            # First branch alone causes failure
            [
              %CreateItem{name: "A1", quantity: 50},
              %CreateItem{name: "A2", quantity: 60}
            ],
            # Second branch is just filler
            [
              %CreateItem{name: "B1", quantity: 5},
              %CreateItem{name: "B2", quantity: 5},
              %CreateItem{name: "B3", quantity: 5}
            ]
          ],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 1,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should shrink the branches
      assert Sequence.command_count(result.sequence) < 5
    end

    test "shrinks prefix while preserving failure" do
      # Prefix has unnecessary commands before the critical ones
      seq =
        Sequence.branching(
          [
            # Unnecessary
            %CreateItem{name: "Filler1", quantity: 5},
            # Unnecessary
            %CreateItem{name: "Filler2", quantity: 5},
            # Needed for failure
            %CreateItem{name: "Critical", quantity: 50}
          ],
          [
            # Combined with prefix: 110 > 100
            [%CreateItem{name: "BranchA", quantity: 60}]
          ],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 3,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should remove some filler commands from prefix
      assert Sequence.command_count(result.sequence) <= 4
    end

    test "shrinks suffix" do
      # Suffix has commands that don't contribute to failure
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 101}],
          [[%CreateItem{name: "Branch", quantity: 10}]],
          [
            %CreateItem{name: "Suffix1", quantity: 5},
            %CreateItem{name: "Suffix2", quantity: 5}
          ]
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Suffix is unnecessary since failure happens in prefix
      # Should remove suffix commands
      shrunk_commands = Sequence.to_list(result.sequence)
      suffix_count = Enum.count(shrunk_commands, fn cmd -> cmd.name =~ "Suffix" end)
      assert suffix_count < 2
    end

    test "returns Sequence struct for branching input" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 101}],
          [[%CreateItem{name: "Branch", quantity: 10}]],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter
        )

      assert %Sequence{} = result.sequence
    end

    test "tracks iterations for branching shrinking" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 101}],
          [[%CreateItem{name: "Branch", quantity: 10}]],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter
        )

      assert is_integer(result.iterations)
      assert result.iterations >= 0
    end

    test "tracks time for branching shrinking" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 101}],
          [[%CreateItem{name: "Branch", quantity: 10}]],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter
        )

      assert is_integer(result.time_ms)
      assert result.time_ms >= 0
    end
  end

  describe "branching argument shrinking" do
    test "shrinks arguments in branching sequence" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "LongPrefixName", quantity: 400}],
          [[%CreateItem{name: "LongBranchName", quantity: 50}]],
          []
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: true)
        )

      # Arguments should be shrunk
      shrunk_commands = Sequence.to_list(result.sequence)
      prefix_cmd = hd(shrunk_commands)

      # Quantity should shrink toward minimum that still fails
      assert prefix_cmd.quantity <= 400
      assert prefix_cmd.quantity > 100
    end
  end

  describe "branching with branch_failure reasons" do
    test "branch_failure is unwrapped for equivalence checking" do
      # This verifies the failure_signature function handles branch_failure
      inner = Failure.assertion_failed(:quantity_limit, "exceeded")
      wrapped = Failure.in_branch(inner, 0)

      # Both should have same signature
      assert Shrinker.failure_signature(inner) == Shrinker.failure_signature(wrapped)
    end

    test "shrinks with branch_failure reason" do
      seq =
        Sequence.branching(
          [],
          [
            [%CreateItem{name: "Branch", quantity: 101}]
          ],
          []
        )

      # Failure in branch 0
      failure_reason = Failure.in_branch(Failure.assertion_failed(:quantity_limit, "exceeded"), 0)

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          failure_reason: failure_reason,
          model: FailingModel,
          adapter: SimpleAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should still shrink correctly
      shrunk_commands = Sequence.to_list(result.sequence)
      assert shrunk_commands != []

      total = Enum.reduce(shrunk_commands, 0, fn cmd, acc -> acc + cmd.quantity end)
      assert total > 100
    end
  end

  # ============================================================================
  # Probe Shrinking Priority Tests (DR-008)
  # ============================================================================

  describe "probe command shrinking priority" do
    alias PropertyDamage.Settle
    alias PropertyDamage.Test.Commands.{CreateItem, ProbeItem}
    alias PropertyDamage.Test.{ProbeAdapter, ProbeModel}

    test "probe commands have :probe semantics" do
      # Verify our test command has the expected semantics
      assert Settle.get_semantics(%ProbeItem{}) == :probe
      assert Settle.get_semantics(%CreateItem{}) == :sync
    end

    test "probe commands are removed before sync commands when both are unnecessary" do
      # Sequence: [CreateItem(5), ProbeItem, CreateItem(101)]
      # The failure is caused by CreateItem(101) alone (exceeds 100 limit)
      # Both CreateItem(5) and ProbeItem are unnecessary
      # The shrinker should try removing ProbeItem first (probe priority)
      commands = [
        %CreateItem{name: "First", quantity: 5},
        %ProbeItem{item_ref: "item_0"},
        %CreateItem{name: "Failing", quantity: 101}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 2,
          model: ProbeModel,
          adapter: ProbeAdapter,
          config: Config.new(shrink_arguments: false)
        )

      # Should shrink to just the failing command
      shrunk_commands = Sequence.to_list(result.sequence)
      assert length(shrunk_commands) == 1
      assert hd(shrunk_commands).quantity == 101

      # Verify no probe commands remain (they were prioritized for removal)
      probe_count = Enum.count(shrunk_commands, fn cmd -> is_struct(cmd, ProbeItem) end)
      assert probe_count == 0
    end

    test "probe commands are removed first even when interspersed" do
      # Sequence with probe commands interspersed among sync commands
      # All contribute to reaching the 100 limit, but probes don't add quantity
      commands = [
        %CreateItem{name: "A", quantity: 40},
        %ProbeItem{item_ref: "item_0"},
        %CreateItem{name: "B", quantity: 40},
        %ProbeItem{item_ref: "item_1"},
        %CreateItem{name: "C", quantity: 30}
      ]

      # Total quantity: 110 > 100, triggers failure
      result =
        Shrinker.shrink(commands,
          failed_at_index: 4,
          model: ProbeModel,
          adapter: ProbeAdapter,
          config: Config.new(shrink_arguments: false)
        )

      shrunk_commands = Sequence.to_list(result.sequence)

      # All probe commands should be removed (they don't contribute to the failure)
      probe_count = Enum.count(shrunk_commands, fn cmd -> is_struct(cmd, ProbeItem) end)
      assert probe_count == 0

      # The CreateItem commands that cause the failure should remain
      total =
        Enum.reduce(shrunk_commands, 0, fn cmd, acc ->
          case cmd do
            %CreateItem{quantity: qty} -> acc + qty
            _ -> acc
          end
        end)

      assert total > 100
    end

    test "probe commands are kept when needed for failure reproduction" do
      # This test verifies that probe commands are only removed if they're truly unnecessary
      # In this case, the probe is unnecessary, so it should be removed
      commands = [
        %CreateItem{name: "Failing", quantity: 101},
        %ProbeItem{item_ref: "item_0"}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          model: ProbeModel,
          adapter: ProbeAdapter,
          config: Config.new(shrink_arguments: false)
        )

      shrunk_commands = Sequence.to_list(result.sequence)

      # The failing CreateItem should remain
      assert shrunk_commands != []
      create_count = Enum.count(shrunk_commands, fn cmd -> is_struct(cmd, CreateItem) end)
      assert create_count >= 1
    end

    test "sort_indices_by_shrink_priority orders probe commands first" do
      # This is a unit test for the internal prioritization function
      # We test it indirectly by checking shrinking behavior
      commands = [
        %CreateItem{name: "Sync1", quantity: 10},
        %ProbeItem{item_ref: "probe1"},
        %CreateItem{name: "Sync2", quantity: 10},
        %ProbeItem{item_ref: "probe2"},
        %CreateItem{name: "Failing", quantity: 101}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 4,
          model: ProbeModel,
          adapter: ProbeAdapter,
          config: Config.new(shrink_arguments: false, max_iterations: 10)
        )

      # With limited iterations, probe commands should be tried first
      # and removed before sync commands
      shrunk_commands = Sequence.to_list(result.sequence)
      probe_count = Enum.count(shrunk_commands, fn cmd -> is_struct(cmd, ProbeItem) end)

      # Probes should be removed first (they're prioritized and unnecessary)
      assert probe_count == 0
    end

    test "probe priority works with branching sequences" do
      # Test that probe priority also works for branching sequence shrinking
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 101}],
          [
            [
              %ProbeItem{item_ref: "probe_a"},
              %CreateItem{name: "BranchA", quantity: 5}
            ],
            [
              %ProbeItem{item_ref: "probe_b"},
              %CreateItem{name: "BranchB", quantity: 5}
            ]
          ],
          [%ProbeItem{item_ref: "probe_suffix"}]
        )

      result =
        Shrinker.shrink(seq,
          failed_at_index: 0,
          model: ProbeModel,
          adapter: ProbeAdapter,
          config: Config.new(shrink_arguments: false)
        )

      shrunk_commands = Sequence.to_list(result.sequence)

      # Probe commands in branches and suffix should be removed first
      probe_count = Enum.count(shrunk_commands, fn cmd -> is_struct(cmd, ProbeItem) end)
      assert probe_count == 0

      # The failing prefix command should remain
      total =
        Enum.reduce(shrunk_commands, 0, fn cmd, acc ->
          case cmd do
            %CreateItem{quantity: qty} -> acc + qty
            _ -> acc
          end
        end)

      assert total > 100
    end
  end
end
