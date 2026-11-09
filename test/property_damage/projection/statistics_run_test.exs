defmodule PropertyDamage.Model.Projection.StatisticsRunTest do
  use ExUnit.Case, async: false

  alias PropertyDamage.Failure
  alias PropertyDamage.Model.Projection.Statistics

  defmodule Done do
    defstruct [:latency_ms]
  end

  defmodule Work do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule FastAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Work{}, _ctx, _runtime), do: {:ok, [%Done{latency_ms: 5}]}
  end

  defmodule SlowAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Work{}, _ctx, _runtime), do: {:ok, [%Done{latency_ms: 900}]}
  end

  defmodule Sequence do
    use PropertyDamage.Model.Projection
  end

  defmodule BareModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [Work]
    @impl true
    def command_sequence_projection, do: Sequence
    @impl true
    def check_projections, do: [Statistics]
  end

  # A user projection that owns the threshold: it reuses the state and the
  # metric helpers of Statistics and declares its own check.
  defmodule LatencyBudget do
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Model.Projection.Statistics

    @impl true
    def init, do: Statistics.init()

    @impl true
    def apply(state, item), do: Statistics.apply(state, item)

    @check every: 10
    def p99_under_budget(state, _cmd_or_event) do
      p99 = Statistics.compute_metrics(state).p99_latency_ms

      p99 < 500 or
        PropertyDamage.fail!("p99 latency over budget", p99_latency_ms: p99, budget_ms: 500)
    end
  end

  defmodule BudgetModel do
    use PropertyDamage.Model
    @impl true
    def commands, do: [Work]
    @impl true
    def command_sequence_projection, do: Sequence
    @impl true
    def check_projections, do: [LatencyBudget]
  end

  defp run(model, adapter) do
    PropertyDamage.run(
      model: model,
      targets: [adapter],
      max_runs: 2,
      max_commands: 12,
      shrink: false
    )
  end

  test "Statistics listed bare in check_projections/0 completes a run" do
    assert {:ok, _} = run(BareModel, FastAdapter)
  end

  test "a user check over compute_metrics/1 passes under its threshold" do
    assert {:ok, _} = run(BudgetModel, FastAdapter)
  end

  test "a user check over compute_metrics/1 fails the run past its threshold" do
    assert {:error, report} = run(BudgetModel, SlowAdapter)

    assert report.report_kind == :check_failed

    assert %Failure{type: %Failure.Check{name: :p99_under_budget}} =
             PropertyDamage.FailureReport.failure_reason(report)
  end
end
