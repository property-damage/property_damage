defmodule PropertyDamage.LinearizationSoundnessTest do
  @moduledoc """
  Regression suite for the linearization soundness fix (Phase 6c headline).

  Two failure modes are guarded here, in both directions:

  1. **Over-reporting (the bug this suite was born for).** The executor used to
     run each branch's synchronous `@trigger` assertions against that branch's
     *forked* projection state. A fork omits the concurrently-executing sibling
     branches' effects, so a read that legally observed a sibling's write was
     flagged as a consistency violation: `Put k v ∥ Get k` reported as a race
     even though Put-then-Get is a legal serialization. A faithful SUT must
     NEVER be reported as failing; pre-fix it failed on essentially every seed.

  2. **Under-reporting (the over-correction we must not introduce).** A real
     cross-branch invariant violation must still be caught. Two branches that
     are each individually fine but jointly break an invariant (each adds 60 to
     a counter capped at 100) are non-linearizable: no ordering satisfies the
     invariant. The OLD code MISSED this (per-branch assertions saw only 60,
     and the merge never re-ran assertions), so the assertion-aware checker is
     also a soundness *improvement*, not just a false-positive fix.

  The checker's verdict is additionally cross-validated against an INDEPENDENT
  oracle (the linear executor over every permutation), so we are not merely
  trusting the same code path that produces the verdict.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{Executor, Failure, Linearization, Sequence}

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter}
  alias PropertyDamage.Test.ShrinkQuality
  alias PropertyDamage.Test.ShrinkQuality.Commands.{DelKey, GetKey, PutKey}
  alias PropertyDamage.Test.ShrinkQuality.Events.{EntryDeleted, EntryPut, EntryRead}

  @branching [max_branches: 2, branch_probability: 1.0]

  # The 6a lying-delete adapter, reused: delete claims success but never touches
  # the store. The genuine bug needs put -> del -> get on one key.
  defmodule LyingDeleteAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.ShrinkQuality.CorrectAdapter

    @impl true
    def setup(config), do: CorrectAdapter.setup(config)
    @impl true
    def teardown(context), do: CorrectAdapter.teardown(context)
    @impl true
    def execute(%DelKey{key: key}, _ctx, _runtime), do: {:ok, [%EntryDeleted{key: key}]}
    def execute(command, ctx, runtime), do: CorrectAdapter.execute(command, ctx, runtime)
  end

  # ==========================================================================
  # 1. Over-reporting is gone: a faithful SUT is never flagged under branching.
  # ==========================================================================

  describe "a correct SUT is never reported as failing under branching" do
    # This is the headline property. Pre-fix it failed on every seed (the
    # forked-state assertions invented races); post-fix every seed is green.
    for seed <- 1..40 do
      test "seed #{seed}: CorrectAdapter under branching is linearizable" do
        result =
          PropertyDamage.run(
            model: ShrinkQuality.Model,
            adapter: ShrinkQuality.CorrectAdapter,
            seed: unquote(seed),
            max_commands: 20,
            max_runs: 60,
            verbose: false,
            branching: @branching
          )

        assert {:ok, _stats} = result,
               "a faithful SUT must never be reported as failing under branching, " <>
                 "but seed #{unquote(seed)} reported: #{inspect(result)}"
      end
    end
  end

  describe "checker accepts a legal Put || Get serialization" do
    test "a read that observed the concurrent write is consistent" do
      # branch0 = Put k 7, branch1 = Get k; the Get observed 7 (Put serialized
      # first). [Put, Get] explains both the events AND the read-consistency
      # assertion, so the checker must accept it.
      branch_commands = [[%PutKey{key: :k0, value: 7}], [%GetKey{key: :k0}]]

      branch_events = %{
        0 => [entry(%EntryPut{key: :k0, value: 7}, 0)],
        1 => [entry(%EntryRead{key: :k0, value: 7}, 0)]
      }

      assert {:ok, ordering} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 projections(),
                 ShrinkQuality.Model
               )

      # The accepted ordering must place the Put before the Get.
      modules = Enum.map(ordering, fn {_b, _p, cmd} -> cmd.__struct__ end)
      assert modules == [PutKey, GetKey]
    end

    test "a read that observed nil (read-first) is also consistent" do
      branch_commands = [[%PutKey{key: :k0, value: 7}], [%GetKey{key: :k0}]]

      branch_events = %{
        0 => [entry(%EntryPut{key: :k0, value: 7}, 0)],
        1 => [entry(%EntryRead{key: :k0, value: nil}, 0)]
      }

      assert {:ok, ordering} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 projections(),
                 ShrinkQuality.Model
               )

      modules = Enum.map(ordering, fn {_b, _p, cmd} -> cmd.__struct__ end)
      assert modules == [GetKey, PutKey]
    end

    test "three parallel branches: two writers and a reader stay consistent" do
      # Put k 1, Put k 2 (distinct branches), Get k observing 2. Some ordering
      # (..., Put k 2, Get k) explains a read of 2; the checker must find it.
      branch_commands = [
        [%PutKey{key: :k0, value: 1}],
        [%PutKey{key: :k0, value: 2}],
        [%GetKey{key: :k0}]
      ]

      branch_events = %{
        0 => [entry(%EntryPut{key: :k0, value: 1}, 0)],
        1 => [entry(%EntryPut{key: :k0, value: 2}, 0)],
        2 => [entry(%EntryRead{key: :k0, value: 2}, 0)]
      }

      assert {:ok, _ordering} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 projections(),
                 ShrinkQuality.Model
               )
    end
  end

  # ==========================================================================
  # 2. Under-reporting guard: real cross-branch violations are still caught.
  # ==========================================================================

  describe "genuine cross-branch invariant violation is caught" do
    test "checker refutes with the specific assertion when every ordering breaks the invariant" do
      # Each branch adds 60 to a counter capped at 100. Every interleaving ends
      # at 120, so NO ordering satisfies the invariant. Events are predictable
      # (so they are compatible in every ordering): the refutation must be
      # assertion-driven and name the failing check.
      branch_commands = [
        [%CreateItem{name: "A", quantity: 60}],
        [%CreateItem{name: "B", quantity: 60}]
      ]

      branch_events = %{
        0 => [item_created("A", 60, 0)],
        1 => [item_created("B", 60, 0)]
      }

      assert {:no_linearization, refutation} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 failing_projections(),
                 FailingModel
               )

      assert refutation.check_name == :quantity_limit

      assert %Failure{
               type: %Failure.Assertion{
                 kind: :assertion_failed,
                 name: :quantity_limit,
                 detail: {%PropertyDamage.AssertionFailed{}, _st}
               }
             } = refutation.reason
    end

    test "executor reports the cross-branch violation as a branch_failure (old code missed it)" do
      seq =
        Sequence.branching(
          [],
          [
            [%CreateItem{name: "A", quantity: 60}],
            [%CreateItem{name: "B", quantity: 60}]
          ],
          []
        )

      {:ok, result} = Executor.run(seq, FailingModel, SimpleAdapter)

      refute result.success

      assert %Failure{
               type: %Failure.Assertion{kind: :assertion_failed, name: :quantity_limit},
               branch_id: _bid
             } = result.failure_reason
    end

    test "a read no ordering can explain is refuted on event incompatibility (refutation is nil)" do
      # branch1 reads 5, but only value 1 was ever written: no serialization
      # explains the observed event. The refutation is event-based, so its
      # detail is nil (no assertion was the cause).
      branch_commands = [[%PutKey{key: :k0, value: 1}], [%GetKey{key: :k0}]]

      branch_events = %{
        0 => [entry(%EntryPut{key: :k0, value: 1}, 0)],
        1 => [entry(%EntryRead{key: :k0, value: 5}, 0)]
      }

      assert {:no_linearization, nil} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 projections(),
                 ShrinkQuality.Model
               )
    end
  end

  describe "the genuine lying-delete bug is still found and minimally shrunk under branching" do
    # Pre-fix, phantom 2-command put||get repros polluted these seeds; the
    # genuine bug must shrink to the real 3-command put -> del -> get.
    for seed <- [10, 12, 14, 15] do
      test "seed #{seed}: shrinks to put -> del -> get on one key" do
        assert {:error, failure} =
                 PropertyDamage.run(
                   model: ShrinkQuality.Model,
                   adapter: LyingDeleteAdapter,
                   seed: unquote(seed),
                   max_commands: 20,
                   max_runs: 150,
                   verbose: false,
                   branching: @branching
                 )

        commands = Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(failure))

        assert [%PutKey{key: key}, %DelKey{key: key}, %GetKey{key: key}] = commands,
               "expected the genuine 3-command repro, got: #{inspect(commands)}"
      end
    end
  end

  # ==========================================================================
  # 3. Independent oracle: cross-validate the checker against the LINEAR
  #    executor over every permutation (a different code path entirely).
  # ==========================================================================

  describe "checker verdicts agree with an independent linear-executor oracle" do
    test "accepted Put || Get really is reproducible by some serial order" do
      branches = [[%PutKey{key: :k0, value: 7}], [%GetKey{key: :k0}]]

      assert some_serial_order_passes?(
               branches,
               ShrinkQuality.Model,
               ShrinkQuality.CorrectAdapter
             )
    end

    test "refuted cross-branch violation really has no passing serial order" do
      branches = [
        [%CreateItem{name: "A", quantity: 60}],
        [%CreateItem{name: "B", quantity: 60}]
      ]

      refute some_serial_order_passes?(branches, FailingModel, SimpleAdapter)
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp projections, do: %{ShrinkQuality.Projection => ShrinkQuality.Projection.init()}

  defp failing_projections do
    alias PropertyDamage.Test.Projections.{FailingAssertion, ModelState}
    %{ModelState => ModelState.init(), FailingAssertion => FailingAssertion.init()}
  end

  defp entry(event, command_index), do: Entry.from_command(event, command_index, timestamp: 1)

  defp item_created(name, quantity, command_index) do
    alias PropertyDamage.Test.Events.ItemCreated

    Entry.from_command(%ItemCreated{item_ref: nil, name: name, quantity: quantity}, command_index,
      timestamp: 1
    )
  end

  # Independent oracle: a branching execution is linearizable iff SOME serial
  # order of the flattened commands passes when run through the plain LINEAR
  # executor (which applies the normal, sound per-command assertions). This
  # shares no code with Linearization.check beyond the executor's single-command
  # path, so it is a genuine cross-check of the verdict.
  defp some_serial_order_passes?(branches, model, adapter) do
    branches
    |> List.flatten()
    |> permutations()
    |> Enum.any?(fn ordering ->
      seq = %Sequence{prefix: ordering, branches: nil, suffix: []}

      case Executor.run(seq, model, adapter, adapter_config: %{}) do
        {:ok, result} -> result.success
        _ -> false
      end
    end)
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for elem <- list, rest <- permutations(list -- [elem]) do
      [elem | rest]
    end
  end
end
