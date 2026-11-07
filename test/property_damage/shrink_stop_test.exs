defmodule PropertyDamage.ShrinkStopTest do
  # A report records why the shrinker stopped (DR-055): `:done` when it
  # finished or never ran, `:max_iterations` or `:max_time` when a budget ran
  # out first, so the report can warn that its reproduction may not be
  # minimal.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Shrinker.Config
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.ReferenceReport, as: R

  defp ledger, do: R.pay_model(Module.concat(__MODULE__, LedgerModel), R.Ledger)

  # Diverges at root 1 of 3. Every shrink attempt that reproduces waits out
  # the 50 ms convergence bound, so one attempt outlasts a 1 ms time budget.
  defp diverging, do: [R.pay_target("a"), R.pay_target("b", %{at: %{1 => {:sync, 1}}})]

  defp shrunk!(config) do
    assert {:error, %FailureReport{kind: :diverged} = report} =
             R.run(ledger(), diverging(), shrink: true, shrinker_config: config)

    report
  end

  defp stop(report), do: R.field(report, :shrink_stop)

  defp json_stop(report),
    do: report |> Formatter.format(:json) |> Jason.decode!() |> get_in(["shrinking", "stop"])

  test "a run without shrinking stops :done with no iterations" do
    # The shrinker never ran, so nothing stopped it early.
    assert {:error, %FailureReport{} = report} = R.run(ledger(), diverging(), shrink: false)

    assert report.shrink_iterations == 0
    assert stop(report) == :done
  end

  test "a report the shrinker never ran on, a setup failure, stops :done" do
    # A setup failure is reported unshrunk.
    assert {:error, %FailureReport{kind: :setup_failed} = report} =
             R.run(Compare.PayModel, [{R.NoBackendAdapter, name: "s", config: %{}}], shrink: true)

    assert stop(report) == :done
  end

  test "a shrink that converges inside its budget stops :done" do
    # Finishing every shrink cycle within both budgets is :done.
    report = shrunk!(Config.new(max_iterations: 1_000, max_time_ms: 30_000))

    assert report.shrink_iterations in 1..999
    assert stop(report) == :done
    assert json_stop(report) == "done"
  end

  test "a shrink that runs out of iterations stops :max_iterations" do
    # The iteration cap ended the shrink before it converged.
    report = shrunk!(Config.new(max_iterations: 1, max_time_ms: 30_000))

    assert report.shrink_iterations == 1
    assert stop(report) == :max_iterations
    assert json_stop(report) == "max_iterations"
  end

  test "a shrink that runs out of time stops :max_time" do
    # The time budget ended the shrink while iterations were left.
    report = shrunk!(Config.new(max_iterations: 1_000, max_time_ms: 1))

    assert report.shrink_iterations < 1_000
    assert stop(report) == :max_time
    assert json_stop(report) == "max_time"
  end

  test "a shrink that runs out of both budgets stops :max_iterations" do
    # Both budgets exceeded: the iteration cap wins. The one attempt the cap
    # allows waits out a 1000 ms convergence bound, so it also uses up the
    # 300 ms time budget, however late it starts within that budget.
    config = Config.new(max_iterations: 1, max_time_ms: 300)

    assert {:error, %FailureReport{kind: :diverged} = report} =
             R.run(ledger(), diverging(),
               shrink: true,
               shrinker_config: config,
               compare: [converge_within: 1_000]
             )

    assert report.shrink_iterations == 1, "control: the iteration cap was reached"
    assert report.shrink_time_ms >= 300, "control: the time budget was used up too"
    assert stop(report) == :max_iterations
  end
end
