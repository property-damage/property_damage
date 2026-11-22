defmodule PropertyDamage.Next.FullRefundTest do
  # The worked example of fitting a dependent value: a refund that empties
  # its payment. When the shrinker lowers the payment, the stored refund no
  # longer fits its range and is clamped to the new bound, so the plan still
  # empties the payment and still fails. Also: the seeded bug's switch must
  # have fired on the final plan of a shrink, which is what the corpus
  # harness reports.
  #
  # async: false because the corpus engine's tests share the harness's
  # fire logs and run the engine end to end.
  use ExUnit.Case, async: false

  alias PropertyDamage.Corpus.{Engine, Entry, FireLog}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal, Model, Placeholder, Step}
  alias PropertyDamage.Next.Test.FullRefund
  alias PropertyDamage.Next.Test.FullRefund.{Pay, Refund}
  alias PropertyDamage.Next.Test.Surface

  @bug :lost_full_refund

  defp payment(step), do: %Placeholder{step: step, event_index: 0, path: [:payment]}

  # Pays `paid` at slot 1 and refunds `refund` of it at slot 2, its range
  # recorded as the one the payment gave when the refund was drawn.
  defp journal(paid, refund, refund_range) do
    specs = Model.specs!(FullRefund.Model)
    pay_id = Enum.find_value(specs, &(&1.command == Pay and &1.id))
    refund_id = Enum.find_value(specs, &(&1.command == Refund and &1.id))

    %Journal{
      seed: 1,
      max_steps: 2,
      fingerprint: Journal.fingerprint(specs),
      entries: %{
        {{0, 1}, :pick} => {:pick, pay_id, Pay},
        {{0, 1}, :command, :amount} => {:integer, paid, 1..1000},
        {{0, 2}, :pick} => {:pick, refund_id, Refund},
        {{0, 2}, :command, :payment} => {:member, payment({0, 1}), 0},
        {{0, 2}, :command, :amount} => {:integer, refund, refund_range}
      }
    }
  end

  defp replay(journal, adapter \\ FullRefund.Adapter, log \\ nil) do
    Next.replay(journal,
      model: FullRefund.Model,
      adapter: adapter,
      config: %{bug: @bug, fire_log: log}
    )
  end

  defp run(seed, adapter, log) do
    Next.run(
      model: FullRefund.Model,
      adapter: adapter,
      seed: seed,
      max_steps: 6,
      max_plans: 200,
      config: %{bug: @bug, fire_log: log}
    )
  end

  defp with_log(fun) do
    {:ok, log} = FireLog.start_link()

    try do
      fun.(log)
    after
      FireLog.stop(log)
    end
  end

  defp entry(adapter) do
    %Entry{
      name: "full_refund",
      engine: Engine.Next,
      system: FullRefund.System,
      bug: @bug,
      model: FullRefund.Model,
      adapter: adapter,
      minimum: [%{command: :pay, amount: 101}, %{command: :refund, payment: :id, amount: 101}],
      max_commands: 6
    }
  end

  describe "the worked example" do
    test "pay 665 and refund 665 fails" do
      plan = Next.plan(FullRefund.Model, journal(665, 665, 1..665))

      assert [%Step{command: %Pay{amount: 665}}, %Step{command: refund}] = plan.steps
      assert refund == %Refund{payment: payment({0, 1}), amount: 665}
      assert {:error, %Failure{step: {0, 2}}} = replay(plan.journal)
    end

    test "lowering the payment to 400 clamps the refund to 400, and the plan still fails" do
      edited = journal(400, 665, 1..665)
      plan = Next.plan(FullRefund.Model, edited)

      assert [%Step{command: %Pay{amount: 400}}, %Step{command: refund}] = plan.steps
      assert refund == %Refund{payment: payment({0, 1}), amount: 400}
      assert plan.journal.entries[{{0, 2}, :command, :amount}] == {:integer, 400, 1..400}

      assert {:error, %Failure{step: {0, 2}, reason: {:check, :balance_matches, _}}} =
               replay(edited)
    end

    test "a shrink ends on a plan no larger than the one found, failing the same way and replaying identically" do
      # The smallest plan, pay 101 and refund 101, is a corpus measurement,
      # not something this test forces.
      found =
        for seed <- 1..6,
            {:error, %Failure{} = failure} <- [run(seed, FullRefund.Adapter, nil)] do
          original = Surface.field(failure, :original)

          assert {:check, :balance_matches, _} = failure.reason
          assert {:check, :balance_matches, _} = original.reason
          assert length(failure.plan.steps) <= length(original.plan.steps)

          loaded = failure.journal |> Journal.to_binary() |> Journal.from_binary()
          assert {:error, %Failure{} = again} = replay(loaded)
          assert again.plan.steps == failure.plan.steps
          assert again.withdrawn == failure.withdrawn
          assert again.step == failure.step
          assert again.reason == failure.reason
          seed
        end

      assert length(found) >= 3
    end
  end

  describe "the seeded bug's switch" do
    test "replaying the final journal of a shrink fires the bug" do
      for seed <- 1..4 do
        case with_log(&run(seed, FullRefund.Adapter, &1)) do
          {:error, %Failure{} = failure} ->
            assert Surface.field(failure, :shrink_runs) > 0

            with_log(fn log ->
              assert {:error, %Failure{}} = replay(failure.journal, FullRefund.Adapter, log)
              assert FireLog.total(log) > 0
              assert FireLog.fired_in_last_instance?(log)
            end)

          {:ok, _} ->
            :ok
        end
      end
    end

    test "when the last system started is not the one that ran the final plan, the last-instance reading is wrong" do
      # The spare adapter starts an idle system after every execution, so the
      # most recently started instance never runs a plan.
      checked =
        for seed <- 1..4 do
          with_log(fn log ->
            case run(seed, FullRefund.SpareAdapter, log) do
              {:error, %Failure{} = failure} ->
                refute FireLog.fired_in_last_instance?(log)

                with_log(fn replay_log ->
                  assert {:error, %Failure{}} =
                           replay(failure.journal, FullRefund.SpareAdapter, replay_log)

                  assert FireLog.total(replay_log) > 0
                end)

                true

              {:ok, _} ->
                false
            end
          end)
        end

      assert Enum.any?(checked)
    end

    test "the corpus engine reads whether the bug fired from the run of the final plan" do
      # With the spare adapter the most recently started system never ran a
      # plan, so only a reading taken from the final plan's run sees the fire.
      for adapter <- [FullRefund.Adapter, FullRefund.SpareAdapter], seed <- 1..3 do
        result = Engine.Next.run(entry(adapter), seed, 200)

        assert result.found?, "#{inspect(adapter)}, seed #{seed}: not found"
        assert result.bug_fired?, "#{inspect(adapter)}, seed #{seed}: bug_fired? is false"
      end
    end

    test "the corpus engine shrinks the failure it reports" do
      for seed <- 1..3 do
        result = Engine.Next.run(entry(FullRefund.Adapter), seed, 200)

        assert result.found?
        assert result.shrink_runs > 0
      end
    end

    test "with the bug off, the corpus engine finds nothing and reads no fire" do
      for adapter <- [FullRefund.Adapter, FullRefund.SpareAdapter], seed <- 1..2 do
        result = Engine.Next.run(%{entry(adapter) | bug: nil}, seed, 50)

        refute result.found?
        refute result.bug_fired?
        assert result.fires == 0
      end
    end
  end
end
