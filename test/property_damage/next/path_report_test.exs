defmodule PropertyDamage.Next.PathReportTest do
  # The run report of a model that states paths: `plans` counts plans, not
  # executions; the withdrawn slots appear once; the assign counts cover
  # every call of `execute/3` in both executions, so a split step that sets
  # an assign counts once in the reference and once per command in the
  # variant; and an assign no port acknowledges still fails the run.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Report}
  alias PropertyDamage.Next.Test.Paths
  alias PropertyDamage.Next.Test.Paths.{AssignModel, Recorded, SplitModel}

  @max_steps 6

  defp run(model, seed, opts) do
    [
      model: model,
      adapter: Paths.Adapter,
      seed: seed,
      max_steps: @max_steps,
      max_plans: 1,
      config: %{recorder: self(), ack: true}
    ]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  defp sum(rows, field), do: rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()

  defp calls(executions), do: executions |> Enum.map(&length(&1.calls)) |> Enum.sum()

  test "plans counts plans, not executions" do
    assert {:ok, %Report{plans: 4}} = run(AssignModel, 1, max_plans: 4)
    assert length(Recorded.executions()) == 2 * 4
  end

  test "assign counts cover every call of both executions" do
    checked =
      for seed <- 1..5 do
        assert {:ok, %Report{assigns: assigns}} = run(AssignModel, seed, [])
        plan = Next.plan(AssignModel, seed, max_steps: @max_steps)
        rows = Map.fetch!(assigns, Paths.Adapter)

        path_calls = plan.steps |> Enum.map(&length(Recorded.path_commands(&1))) |> Enum.sum()
        expected = length(plan.steps) + path_calls

        assert calls(Recorded.executions()) == expected
        assert Enum.all?(rows, &(&1.key == :tag))
        assert sum(rows, :set) == expected
        assert sum(rows, :acknowledged) == expected

        path_calls > length(plan.steps)
      end

    assert Enum.any?(checked), "no seed ran a split"
  end

  test "an assign no port acknowledges still fails the run, with the counts of both executions" do
    assert {:error, %Failure{reason: {:unacknowledged_assigns, rows}, plan: nil, step: nil}} =
             run(AssignModel, 2, config: %{recorder: self()})

    plan = Next.plan(AssignModel, 2, max_steps: @max_steps)
    path_calls = plan.steps |> Enum.map(&length(Recorded.path_commands(&1))) |> Enum.sum()

    assert length(Recorded.executions()) == 2
    assert Enum.all?(rows, &(&1.key == :tag and &1.acknowledged == 0))
    assert sum(rows, :set) == length(plan.steps) + path_calls
  end

  test "shrink candidates stay uncounted: the counts are those of the search plans' two executions" do
    assert {:error, %Failure{plan_number: number, report: report} = failure} =
             run(AssignModel, 1,
               max_plans: 50,
               config: %{recorder: self(), ack: true, peek_error: true}
             )

    searched = Recorded.executions() |> Enum.take(2 * number)
    rows = Map.fetch!(report.assigns, Paths.Adapter)

    assert failure.shrink_runs > 0
    assert sum(rows, :set) == calls(searched)
    assert sum(rows, :acknowledged) == calls(searched)
  end

  test "the withdrawn slots of a failing run appear once, as the failure lists them" do
    for seed <- 1..3 do
      assert {:error, %Failure{} = failure} =
               run(SplitModel, seed, max_plans: 100, config: %{bug: :short_second_refund})

      assert failure.report.withdrawn == failure.withdrawn
      assert Enum.uniq(failure.report.withdrawn) == failure.report.withdrawn
      assert failure.report.plans == failure.plan_number
    end
  end
end
