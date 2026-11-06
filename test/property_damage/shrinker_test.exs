defmodule PropertyDamage.ShrinkerTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Sequence, Shrinker}
  alias PropertyDamage.Shrinker.Config

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter}

  # ============================================================================
  # Failure Equivalence Tests
  # ============================================================================

  describe "failure_signature/2" do
    test "extracts {kind, name} from a check failure" do
      reason = Failure.check_failed(:balance_invariant, "Balance negative")
      assert Shrinker.failure_signature(reason, 0) == {:check_failed, :balance_invariant, 0}
    end

    test "extracts signature from idempotency_violation" do
      reason = Failure.idempotency_violation(%{command: %{}, events: []})
      assert Shrinker.failure_signature(reason, 0) == {:idempotency_violation, nil, 0}
    end

    test "extracts signature from adapter_error" do
      reason = Failure.adapter_error(:connection_refused)
      assert Shrinker.failure_signature(reason, 0) == {:adapter_error, nil, 0}
    end

    test "extracts signature from placeholder_resolution" do
      reason = Failure.placeholder_resolution(:unknown_placeholder)
      assert Shrinker.failure_signature(reason, 0) == {:placeholder_resolution, nil, 0}
    end

    test "extracts signature from stutter_execution_failed" do
      reason = Failure.stutter_execution_failed(:timeout)
      assert Shrinker.failure_signature(reason, 0) == {:stutter_execution_failed, nil, 0}
    end

    test "handles non-Failure reasons" do
      assert Shrinker.failure_signature(:error, 0) == {:unknown, nil, 0}
      assert Shrinker.failure_signature("string", 0) == {:unknown, nil, 0}
      assert Shrinker.failure_signature(123, 0) == {:unknown, nil, 0}
    end

    test "named check failures carry the check name (DR-025)" do
      reason = Failure.check_failed(:counter_never_exceeds, {%RuntimeError{}, []})
      assert Shrinker.failure_signature(reason, 0) == {:check_failed, :counter_never_exceeds, 0}
    end

    test "a poll_timeout and a check failure of the SAME name are NOT equivalent" do
      # Load-bearing (DR-041 D4): both name themselves :ledger_settles, but they
      # are different bugs. Keying the signature on the globally-unique KIND (not
      # the coarser class) keeps them distinct; a class-based signature
      # ({:check, :ledger_settles} for both) would merge them and let the
      # shrinker swap a poll-timeout for an invariant violation of the same name.
      name = :ledger_settles

      poll =
        Failure.poll_timeout(%{
          triggered_by: %{check_name: name},
          elapsed_ms: 10,
          poll_count: 1
        })

      check = Failure.check_failed(name, {%RuntimeError{}, []})

      assert Shrinker.failure_signature(poll, 0) == {:poll_timeout, name, 0}
      assert Shrinker.failure_signature(check, 0) == {:check_failed, name, 0}
      refute Shrinker.equivalent_failures?({poll, 0}, {check, 0})
    end
  end

  describe "equivalent_failures?/2" do
    test "same check failure with same name are equivalent" do
      reason1 = Failure.check_failed(:balance, "Balance is -50")
      reason2 = Failure.check_failed(:balance, "Balance is -100")
      assert Shrinker.equivalent_failures?({reason1, 0}, {reason2, 0})
    end

    test "same check failure with different names are not equivalent" do
      reason1 = Failure.check_failed(:balance, "Error")
      reason2 = Failure.check_failed(:consistency, "Error")
      refute Shrinker.equivalent_failures?({reason1, 0}, {reason2, 0})
    end

    test "distinct check failures are not equivalent, same one is (DR-025)" do
      a = Failure.check_failed(:counter_never_exceeds, {%RuntimeError{}, []})
      b = Failure.check_failed(:other_invariant, {%RuntimeError{}, []})
      # An async-observed failure and a teardown failure of the SAME check
      # carry the same name, so they remain equivalent for shrinking.
      a_again =
        Failure.check_failed(:counter_never_exceeds, {%ArgumentError{}, [{:mod, :f, 1, []}]})

      refute Shrinker.equivalent_failures?({a, 0}, {b, 0})
      assert Shrinker.equivalent_failures?({a, 0}, {a_again, 0})
    end

    test "different failure kinds are not equivalent" do
      check = Failure.check_failed(:balance, "Error")
      idempotency = Failure.idempotency_violation(%{})
      adapter = Failure.adapter_error(:timeout)

      refute Shrinker.equivalent_failures?({check, 0}, {idempotency, 0})
      refute Shrinker.equivalent_failures?({check, 0}, {adapter, 0})
      refute Shrinker.equivalent_failures?({idempotency, 0}, {adapter, 0})
    end

    test "same non-check failure kinds are equivalent" do
      reason1 = Failure.idempotency_violation(%{first: 1})
      reason2 = Failure.idempotency_violation(%{second: 2})
      assert Shrinker.equivalent_failures?({reason1, 0}, {reason2, 0})
    end

    test "the same failure in another target is not equivalent" do
      reason = Failure.check_failed(:balance, "Error")

      assert Shrinker.failure_signature(reason, 1) == {:check_failed, :balance, 1}
      refute Shrinker.equivalent_failures?({reason, 0}, {reason, 1})
      assert Shrinker.equivalent_failures?({reason, 1}, {reason, 1})
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
        Failure.check_failed(:high_limit, "Quantity 250 exceeds high limit of 200")

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          failure_reason: failure_reason,
          model: MultiCheckModel,
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ]
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ]
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ]
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
          config: Config.new(max_iterations: 5, shrink_arguments: false)
        )

      assert result.iterations <= 5
    end

    test "max_iterations: 0 tries no candidate, the truncation after the failing root included" do
      commands = [
        %CreateItem{name: "A", quantity: 60},
        %CreateItem{name: "B", quantity: 60},
        %CreateItem{name: "C", quantity: 1},
        %CreateItem{name: "D", quantity: 1}
      ]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 1,
          model: FailingModel,
          targets: [
            %PropertyDamage.Target{adapter: SimpleAdapter, config: %{}, name: "a", index: 0}
          ],
          config: Config.new(max_iterations: 0)
        )

      assert result.iterations == 0
      assert Sequence.to_list(result.sequence) == commands
    end

    test "respects max_time_ms" do
      commands = [%CreateItem{name: "Failing", quantity: 101}]

      result =
        Shrinker.shrink(commands,
          failed_at_index: 0,
          model: FailingModel,
          targets: [
            %PropertyDamage.Target{
              adapter: SimpleAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: ProbeAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: ProbeAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: ProbeAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
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
          targets: [
            %PropertyDamage.Target{
              adapter: ProbeAdapter,
              config: %{},
              name: "adapter",
              index: 0
            }
          ],
          config: Config.new(shrink_arguments: false, max_iterations: 10)
        )

      # With limited iterations, probe commands should be tried first
      # and removed before sync commands
      shrunk_commands = Sequence.to_list(result.sequence)
      probe_count = Enum.count(shrunk_commands, fn cmd -> is_struct(cmd, ProbeItem) end)

      # Probes should be removed first (they're prioritized and unnecessary)
      assert probe_count == 0
    end
  end

  # ============================================================================
  # A candidate whose validation raises
  # ============================================================================

  # Divide's divisor shrinks toward 0, and the model's projection divides by it,
  # so argument shrinking makes up a candidate the projection raises on.
  defmodule Divide do
    use PropertyDamage.Command
    defstruct [:by]

    @impl true
    def generator(overrides \\ %{}) do
      %{by: StreamData.integer(5..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Divided, do: defstruct([:by])

  defmodule Quotient do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{quotient: nil}

    @impl true
    def apply(state, %Divide{by: by}), do: %{state | quotient: div(100, by)}
    def apply(state, _), do: state
  end

  defmodule NoDivisions do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: Divided
    def assert_no_division(_state, _event), do: PropertyDamage.fail!("divided")
  end

  defmodule DivideModel do
    use PropertyDamage.Model

    @impl true
    def commands, do: [Divide]

    @impl true
    def command_sequence_projection, do: Quotient

    @impl true
    def check_projections, do: [NoDivisions]
  end

  defmodule DivideAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Divide{by: by}, _ctx, _runtime), do: {:ok, [%Divided{by: by}]}
  end

  describe "a candidate whose validation raises" do
    test "is rejected as invalid, and run/1 still returns the shrunk failure" do
      assert {:error, %PropertyDamage.FailureReport{} = report} =
               PropertyDamage.run(
                 model: DivideModel,
                 targets: [{DivideAdapter, name: "only", config: %{}}],
                 max_runs: 1,
                 max_commands: 5,
                 seed: 1,
                 validate: false
               )

      assert Failure.kind(report.failure_reason) == :check_failed

      shrunk =
        report |> PropertyDamage.FailureReport.shrunk_sequence() |> Sequence.to_list()

      # Halving 5..9 reaches 1; the next halving, 0, makes the projection raise.
      assert shrunk == [%Divide{by: 1}]
    end
  end
end
