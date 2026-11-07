defmodule PropertyDamage.FailureReportReferenceTest do
  # A comparison failure (`:diverged`, `:did_not_converge`) keeps the
  # reference target's trace of the reported run and the reference's
  # projection state at the failing boundary, so a reader sees both sides
  # (DR-055). Every other kind leaves both nil.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.{FailureReport, RunTrace, Sequence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.{Compare, ExpansionRun, SetupCommands}
  alias PropertyDamage.Test.Compare.{Paid, Settled}
  alias PropertyDamage.Test.ReferenceReport, as: R

  @stops ["done", "max_iterations", "max_time"]

  defp ledger, do: R.pay_model(Module.concat(__MODULE__, LedgerModel), R.Ledger)

  # "b" settles its Pay number 1 with one too many, so the run diverges at
  # root 1 of 3.
  defp diverging, do: [R.pay_target("a"), R.pay_target("b", %{at: %{1 => {:sync, 1}}})]

  # "b" never settles its Pay number 1, so the run does not converge there.
  defp stalling, do: [R.pay_target("a"), R.pay_target("b", %{at: %{1 => :never}})]

  defp failure!(result) do
    assert {:error, %FailureReport{} = report} = result
    report
  end

  defp reference_trace(report), do: R.field(report, :reference_trace)
  defp reference_state(report), do: R.field(report, :reference_state_at_failure)

  defp json(report), do: report |> Formatter.format(:json) |> Jason.decode!()

  defp paid_by(json_log),
    do: for(%{"event_type" => "Paid", "event" => %{"by" => by}} <- json_log, do: by)

  defp roots(report), do: report.trace.plan |> Sequence.to_list()

  # The reference settles every Pay at once, so its total at a boundary is
  # the sum of the amounts up to that root.
  defp settled_through(report, root),
    do: report |> roots() |> Enum.take(root + 1) |> Enum.map(& &1.amount) |> Enum.sum()

  defp steps_by(steps, module),
    do: for(step <- steps, %{event: %{__struct__: ^module, by: by}} <- step.entries, do: by)

  # The last fold a trace attributes to root `root`: the root's own fold and
  # the folds of its events.
  defp last_fold_of_root(%RunTrace{} = trace, root) do
    own = Map.fetch!(trace.command_fold_ordinals, Position.prefix(root))

    events =
      for %{command_index: ^root, phase: :root, fold_index: fold} <- trace.event_log,
          fold != nil,
          do: fold

    Enum.max([own | events])
  end

  describe "JSON of a comparison failure" do
    test "a divergence names the reference trace, keeps each side's events and adds the reference's projections" do
      # The JSON carries the reference's trace and state beside the variant's.
      report = failure!(R.run(ledger(), diverging()))
      assert %{kind: :diverged, variant: %{index: 1, name: "b"}, failed_at_index: 1} = report

      json = json(report)
      settled = settled_through(report, 1)
      assert Enum.uniq(paid_by(json["event_log"])) == ["b"]
      assert get_in(json, ["projections", "Ledger", "settled"]) == settled + 1

      reference = Map.fetch!(json, "reference_trace")

      for key <-
            ~w(target seed run_number mint_epoch plan_source plan_fingerprint sequence event_log) do
        assert Map.has_key?(reference, key), "reference_trace lacks #{inspect(key)}"
      end

      assert reference["target"] == "a"
      assert reference["seed"] == report.seed
      assert reference["sequence"] == json["sequence"]
      assert [_ | _] = paid_by(reference["event_log"])
      assert Enum.uniq(paid_by(reference["event_log"])) == ["a"]
      assert get_in(json, ["reference_projections", "Ledger", "settled"]) == settled
      assert get_in(json, ["shrinking", "stop"]) in @stops
    end

    test "a failure to converge names the reference trace and the reference's settled projections" do
      # The JSON of a :did_not_converge carries the reference side too.
      report = failure!(R.run(ledger(), stalling()))

      assert %{kind: :did_not_converge, variant: %{index: 1, name: "b"}, failed_at_index: 1} =
               report

      json = json(report)
      assert Enum.uniq(paid_by(json["event_log"])) == ["b"]
      assert get_in(json, ["projections", "Ledger", "unsettled"]) != %{}

      assert %{"target" => "a"} = Map.fetch!(json, "reference_trace")
      assert Enum.uniq(paid_by(json["reference_trace"]["event_log"])) == ["a"]

      assert %{"unsettled" => %{}, "settled" => settled} =
               get_in(json, ["reference_projections", "Ledger"])

      assert settled == settled_through(report, 1)
      assert get_in(json, ["shrinking", "stop"]) in @stops
    end

    test "a one-target check failure, a setup failure and a command timeout carry both keys as null" do
      # Only comparison failures have a reference side; the keys are always present.
      check =
        failure!(R.run(Compare.PlainModel, [R.pay_target("a", %{at: %{0 => {:sync, -100}}})]))

      setup = failure!(R.run(Compare.PayModel, [{R.NoBackendAdapter, name: "s", config: %{}}]))
      timeout = failure!(R.run(Compare.PayModel, [{R.TimeoutAdapter, name: "t", config: %{}}]))

      assert check.kind == :check_failed
      assert setup.kind == :setup_failed
      assert timeout.kind == :execution_failed

      assert Compare.deep_find(
               timeout.failure_reason,
               &is_struct(&1, PropertyDamage.CommandTimeoutError)
             )

      for report <- [check, setup, timeout] do
        json = json(report)
        assert Map.fetch!(json, "reference_trace") == nil, "#{report.kind}: reference_trace"
        assert Map.fetch!(json, "reference_projections") == nil, "#{report.kind}: projections"
        assert get_in(json, ["shrinking", "stop"]) == "done", "#{report.kind}: stop"
        assert reference_trace(report) == nil
        assert reference_state(report) == nil
      end
    end
  end

  describe "the reference trace comes from the reported run" do
    test "a shrunk reproduction: both traces share the seed, the shrunk plan and its mint epoch" do
      # The reference trace is the reproduction's, not the exploration run's.
      report = failure!(R.run(ledger(), diverging(), shrink: true))
      trace = report.trace
      assert Sequence.command_count(trace.plan) < Sequence.command_count(report.original_sequence)
      assert trace.plan_source == :shrunk
      assert trace.mint_epoch > 0

      reference = reference_trace(report)
      assert %RunTrace{} = reference
      assert reference.plan_source == :shrunk
      assert reference.mint_epoch == trace.mint_epoch
      assert reference.seed == trace.seed
      assert reference.plan_fingerprint == trace.plan_fingerprint
      refute reference.plan_fingerprint == RunTrace.plan_fingerprint(report.original_sequence)
      assert Enum.uniq(R.by_of(reference.event_log, Paid)) == ["a"]
    end

    test "a shrunk run that did not reproduce: both traces are the exploration run's" do
      # A failed reproduction falls back to the original run for both targets.
      entries = [R.pay_target("a"), R.first_execution_target("b", %{1 => {:sync, 1}})]
      report = failure!(R.run(ledger(), entries, shrink: true))
      assert report.kind == :diverged
      assert report.shrink_iterations > 0
      original = RunTrace.plan_fingerprint(report.original_sequence)

      assert {report.trace.mint_epoch, report.trace.plan_source, report.trace.plan_fingerprint} ==
               {0, :generated, original}

      reference = reference_trace(report)
      assert %RunTrace{} = reference

      assert {reference.mint_epoch, reference.plan_source, reference.plan_fingerprint} ==
               {0, :generated, original}

      assert Enum.uniq(R.by_of(reference.event_log, Paid)) == ["a"]
    end
  end

  describe "the reference state at the failing boundary" do
    test "leaves out the events of the teardown commands" do
      # Teardown commands run after the boundary, so their events are not in it.
      recorder = start_recorder()
      model = R.teardown_model(Module.concat(__MODULE__, TeardownModel))

      targets = [
        SetupCommands.target("a", recorder),
        SetupCommands.target("b", recorder, %{mode: :shift})
      ]

      report = failure!(R.run(model, targets))
      assert report.kind == :diverged

      assert Enum.any?(
               reference_trace(report).event_log,
               &(&1.phase == :teardown and match?(%SetupCommands.Noted{by: "a"}, &1.event))
             ),
             "control: the reference's teardown command answered a Noted event"

      assert Map.fetch!(reference_state(report), R.Tally) ==
               %{acts: report.failed_at_index + 1, noted: 0, by: "a", mode: :plain}
    end

    test "leaves out an event that folded while the reference finalized its run" do
      # Finalization folds after the boundary, so the boundary state lacks its events.
      model = R.pay_model(Module.concat(__MODULE__, SettlesModel), R.Settles)

      # Both targets settle Pay number 0 after 800 ms, long after the
      # divergence at root 1 ends the run; finalization awaits that poller.
      targets = [
        R.pay_target("a", %{at: %{0 => {:after_ms, 800}}}),
        R.pay_target("b", %{at: %{0 => {:after_ms, 800}, 1 => {:sync, 1}}})
      ]

      report = failure!(R.run(model, targets))
      root = report.failed_at_index
      assert {report.kind, root} == {:diverged, 1}
      assert root < length(roots(report)) - 1, "the failing root must not be the last"

      reference = reference_trace(report)
      late = Enum.find(reference.event_log, &match?(%Settled{n: 0}, &1.event))
      assert late, "control: the reference's settlement of Pay 0 is in its trace"

      assert late.fold_index > last_fold_of_root(reference, root),
             "control: that settlement folded after the failing boundary"

      amount = report |> roots() |> Enum.at(root) |> Map.fetch!(:amount)

      assert Map.fetch!(reference_state(report), R.Settles) ==
               %{settled: %{root => amount}, by: "a"}
    end

    test "includes the folds of the leaves the reference ran for an expanded root" do
      # A root run as expansion leaves contributes its leaf commands' folds.
      model = R.leaf_model(Module.concat(__MODULE__, LeafModel))

      report =
        Enum.find_value(1..10, fn seed ->
          recorder = start_recorder()

          targets = [
            ExpansionRun.target("alpha", recorder),
            ExpansionRun.target("beta", recorder, %{bug: :credit})
          ]

          case R.run(model, targets, seed: seed, max_commands: 6) do
            {:error, %FailureReport{kind: :diverged} = report} -> report
            _other -> nil
          end
        end) || flunk("no seed in 1..10 diverges")

      root = report.failed_at_index

      assert %{leaves: [ExpansionRun.Credit, ExpansionRun.Credit]} =
               report.expansions |> Map.fetch!("alpha") |> Enum.at(root),
             "control: the reference ran the failing root as two Credit leaves"

      refunds =
        report
        |> roots()
        |> Enum.take(root + 1)
        |> Enum.filter(&match?(%ExpansionRun.Refund{}, &1))

      # Hand-computed: every Refund ran as two Credit leaves whose amounts
      # add up to the Refund's; the reference credits exactly.
      expected = %{
        credit_commands: 2 * length(refunds),
        credited: refunds |> Enum.map(& &1.amount) |> Enum.sum(),
        by: "alpha"
      }

      assert expected.credit_commands > 0
      assert Map.fetch!(reference_state(report), R.LeafTally) == expected
    end
  end

  describe "accessors" do
    test "steps/1 and event_log/1 stay the variant's; the reference has its own" do
      # The existing accessors keep meaning the failing target's trace.
      report = failure!(R.run(ledger(), diverging()))
      assert Enum.uniq(steps_by(FailureReport.steps(report), Paid)) == ["b"]
      assert Enum.uniq(R.by_of(FailureReport.event_log(report), Paid)) == ["b"]

      reference_steps = R.call(FailureReport, :reference_steps, [report])
      reference_log = R.call(FailureReport, :reference_event_log, [report])

      assert Enum.map(reference_steps, & &1.position) ==
               Enum.map(FailureReport.steps(report), & &1.position)

      assert Enum.uniq(steps_by(reference_steps, Paid)) == ["a"]
      assert Enum.uniq(R.by_of(reference_log, Paid)) == ["a"]
    end

    test "the reference accessors return [] for a one-target report" do
      # A report without a reference side has no reference steps or events.
      report =
        failure!(R.run(Compare.PlainModel, [R.pay_target("a", %{at: %{0 => {:sync, -100}}})]))

      assert R.call(FailureReport, :reference_steps, [report]) == []
      assert R.call(FailureReport, :reference_event_log, [report]) == []
    end
  end

  describe "re-shrinking a divergence" do
    test "takes both traces from the re-shrink's reproduction and records its own stop" do
      # shrink_further/2 rebuilds the reference side from its own reproduction.
      report = failure!(R.run(ledger(), diverging()))
      assert {:ok, further} = PropertyDamage.shrink_further(report, max_iterations: 1)
      assert further.kind == :diverged
      assert further.shrink_iterations == 1
      refute further.trace.mint_epoch == report.trace.mint_epoch
      assert further.trace.plan_source == :shrunk

      assert R.field(report, :shrink_stop) == :done
      reference = reference_trace(further)

      assert %RunTrace{} = reference
      assert reference.seed == further.trace.seed
      assert reference.mint_epoch == further.trace.mint_epoch
      assert reference.plan_fingerprint == further.trace.plan_fingerprint
      assert reference.plan_source == :shrunk
      refute reference.mint_epoch == reference_trace(report).mint_epoch
      assert R.field(further, :shrink_stop) == :max_iterations

      assert get_in(reference_state(further), [R.Ledger, :settled]) ==
               settled_through(further, further.failed_at_index)
    end
  end
end
