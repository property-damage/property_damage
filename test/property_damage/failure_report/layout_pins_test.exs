defmodule PropertyDamage.FailureReport.LayoutPinsTest do
  # Assumptions the layout makes about the report it prints, each pinned with
  # a control that shows the check can fail: leaves listed contiguously after
  # their root, calls that bind `targets` by text, the event a projection
  # header names when the trace has no fold ordinals, and an `Other failure`
  # that is a failure to converge.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport
  alias PropertyDamage.RunTrace.Step
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.{ExpansionRun, VariantSupport}
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.ReportLayout, as: L

  defmodule SixthCreditFails do
    @moduledoc false
    # Counts Credited events and fails on the sixth: the second leaf of the
    # third Refund when every Refund runs as two Credit leaves.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{credited: 0}

    @impl true
    def apply(state, %ExpansionRun.Credited{}), do: %{state | credited: state.credited + 1}
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.ExpansionRun.Credited
    def assert_fewer_than_six(state, _event) do
      state.credited < 6 or PropertyDamage.fail!("the sixth credit")
    end
  end

  describe "leaves listed after their root" do
    # Leaves of one root follow each other in offset order, and no root's
    # leaves reappear after another root's.
    defp contiguous?(steps) do
      leaves =
        for %Step{position: %Position{section: {:leaf, id}, offset: j}} <- steps, do: {id, j}

      ids = leaves |> Enum.map(&elem(&1, 0)) |> Enum.dedup()

      ids == Enum.uniq(ids) and
        Enum.all?(Enum.group_by(leaves, &elem(&1, 0)), fn {_id, group} ->
          Enum.map(group, &elem(&1, 1)) == Enum.to_list(0..(length(group) - 1))
        end)
    end

    defp three_refund_report do
      model =
        if Code.ensure_loaded?(__MODULE__.ThreeRefundModel) do
          __MODULE__.ThreeRefundModel
        else
          ExpansionRun.define_model!(__MODULE__.ThreeRefundModel,
            commands: [ExpansionRun.Refund],
            expansions: [{ExpansionRun.Refund, &ExpansionRun.refund_rewrite/2}],
            checks: [ExpansionRun.Totals, SixthCreditFails]
          )
        end

      Enum.find_value(1..40, fn seed ->
        targets = [ExpansionRun.target("a", VariantSupport.start_recorder())]

        case R.run(model, targets, seed: seed, max_commands: 6, shrink: false) do
          {:error, %FailureReport{kind: :check_failed} = report} ->
            ids =
              for %Step{position: %Position{section: {:leaf, id}}} <- FailureReport.steps(report),
                  uniq: true,
                  do: id

            if length(ids) >= 3, do: report

          _other ->
            nil
        end
      end)
    end

    test "steps/1 of a report with several expanded roots lists each root's leaves together" do
      report = three_refund_report()
      assert report, "no seed in 1..40 failed at a third expanded root"

      steps = FailureReport.steps(report)
      assert contiguous?(steps)
      assert length(for %Step{position: %Position{section: {:leaf, _}}} <- steps, do: 1) >= 6
    end

    test "control: leaves of two roots interleaved are not contiguous" do
      steps = FailureReport.steps(three_refund_report())
      {first, rest} = Enum.split(steps, 2)

      shuffled =
        Enum.intersperse(Enum.take(rest, 2), hd(first)) ++ tl(first) ++ Enum.drop(rest, 2)

      refute contiguous?(shuffled)
    end

    test "the layout lists each expanded root once, with its leaves under it" do
      report = three_refund_report()
      text = L.plain(report)

      for root <- 0..2 do
        assert text =~ ~r/^\s*(►\s)?\[#{root}\] /m
        assert text =~ "[#{root}.0]"
        assert text =~ "[#{root}.1]"
      end

      assert length(Regex.scan(~r/^[\x{25BA}\s]*\[0\.0\](\s|$)/mu, text)) == 1
    end
  end

  describe "calls that bind targets" do
    # The layout swaps the targets source for `targets` by text, so a call
    # that prints the targets another way would keep a full copy.
    @with_targets [:check_failed, :diverged, :diverged_expanded, :hand_built]

    for kind <- @with_targets do
      test "#{kind}: every call names targets: targets and no copy of the source remains" do
        report = L.report(unquote(kind))
        source = FailureReport.targets_source(report)
        body = report |> L.plain() |> L.section("Reproduction") |> Enum.join("\n")

        assert length(String.split(body, source)) - 1 == 1,
               "the source prints once, as the binding"

        assert body =~ "targets = " <> source

        calls = for "PropertyDamage." <> _ = line <- String.split(body, "\n"), do: line
        assert calls != []
        refute Enum.any?(calls, &(&1 =~ "targets: ["))
        assert Enum.any?(calls, &(&1 =~ "targets: targets"))
      end
    end

    test "control: a call whose targets text differs from the source keeps a full copy" do
      report = L.report(:diverged)
      source = FailureReport.targets_source(report)
      call = "PropertyDamage.run(targets: " <> String.upcase(source) <> ", seed: 1)"

      # What the layout does to a call, applied to the drifted one.
      bound = String.replace(call, "targets: " <> source, "targets: targets")

      assert bound =~ "targets: [",
             "the drifted call is not rebound, so the check above would fail it"
    end
  end

  describe "the event a projection header names without fold ordinals" do
    test "is the step's last event in listed order, not the first" do
      # Root [0]'s events are dropped, so the failing step holds the run's
      # first event as well as its last.
      base = L.report(:hand_built)
      log = Enum.reject(base.trace.event_log, &(&1.command_index == 0))
      report = %{base | trace: %{base.trace | event_log: log}}

      assert report.trace.command_fold_ordinals == %{}

      assert Enum.all?(report.trace.event_log, &is_nil(&1.fold_index)),
             "control: no fold ordinals"

      [header] =
        report
        |> L.plain()
        |> L.section("Projections at ")
        |> Enum.filter(&(&1 =~ "last applied:"))

      # Root [1] lists Settled (+0.38s) then Paid (+0.40s); the log holds them
      # in the other order, and the header follows the listing.
      assert header =~ "last applied: Paid"
      refute header =~ "Settled"
    end
  end

  describe "an Other failure that is a failure to converge" do
    test "prints its kind, name, target and root, then the pending value" do
      failure = L.report(:did_not_converge).failure_reason

      assert PropertyDamage.Failure.kind(failure) == :did_not_converge,
             "control: it did not converge"

      other = %{variant: %{name: "carol", index: 2}, root: 1, failure: failure}
      report = %{L.report(:check_failed) | other_failures: [other]}

      [line] =
        for line <- String.split(L.plain(report), "\n"), line =~ "Other failure", do: line

      name = FailureReport.format_name(PropertyDamage.Failure.name(failure))

      assert line ==
               "Other failure  did not converge #{name} in target \"carol\" (index 2) at root 1  " <>
                 "\"carol\" still pending: #{inspect(failure.type.reason)}"
    end
  end
end
