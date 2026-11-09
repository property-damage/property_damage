defmodule PropertyDamage.CampaignPolicyTest do
  # The run loop's policy, driven with a fake run step: no model, no adapter,
  # no scheduler. The fake records the run numbers it sees and the
  # accumulator it receives, so each test reads the policy off those calls.
  use ExUnit.Case, async: true

  alias PropertyDamage.Campaign
  alias PropertyDamage.Campaign.Context
  alias PropertyDamage.{FailureReport, Progress.Reporter, Target}

  defmodule FakeCommand do
    defstruct []
  end

  defp target, do: %Target{adapter: FakeAdapter, name: "fake", index: 0}

  defp acc do
    %{
      fires: %{},
      compare_counts: %{},
      tracker: nil,
      total_commands: 0,
      setup_commands: 0,
      teardown_commands: 0,
      expansion_counts: %{"fake" => %{}},
      samples: [],
      last_run: nil
    }
  end

  # A context whose run step is `step`. The loop reads the model's invariant
  # catalog when every run passes, so the model is a real test model; it is
  # never run.
  defp context(step, fields \\ []) do
    base = %Context{
      model: PropertyDamage.Test.MinimalModel,
      targets: [target()],
      target: target(),
      reporter: Reporter.new([]),
      seed: 7,
      max_runs: 3,
      run_once: step
    }

    struct!(base, fields)
  end

  # A step that passes, adds the run's number to `total_commands` and
  # reports every call to the test process.
  defp passing_step(test_pid) do
    fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})
      {:pass, %{acc | total_commands: acc.total_commands + run_number + 1}}
    end
  end

  defp seen_runs(acc \\ []) do
    receive do
      {:run, number, seen_acc} -> seen_runs([{number, seen_acc} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "runs exactly max_runs runs when every run passes and returns the stats" do
    ctx = context(passing_step(self()), max_runs: 4)

    assert {:ok, stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0, 1, 2, 3]
    assert stats.runs == 4
    assert stats.seed == 7
    assert stats.total_commands == 1 + 2 + 3 + 4
    assert stats.targets == [%{index: 0, name: "fake"}]
    refute Map.has_key?(stats, :replay)
    refute Map.has_key?(stats, :metrics)
  end

  test "first_run offsets the run numbers, so a single run n sees exactly run n" do
    ctx = context(passing_step(self()), first_run: 4, max_runs: 1)

    assert {:ok, _stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [4]
  end

  test "first_run shifts the whole window of max_runs runs" do
    ctx = context(passing_step(self()), first_run: 2, max_runs: 3)

    assert {:ok, _stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [2, 3, 4]
  end

  test "stops at the first failing run, calls the step no further and returns the error" do
    test_pid = self()

    step = fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})
      if run_number == 1, do: {:error, :found_at_one}, else: {:pass, acc}
    end

    assert Campaign.loop(context(step, max_runs: 5), acc()) == {:error, :found_at_one}

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0, 1]
  end

  test "a failure on the first run is returned with no further call" do
    test_pid = self()

    step = fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})
      {:error, :first}
    end

    assert Campaign.loop(context(step), acc()) == {:error, :first}
    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0]
  end

  test "threads each pass's accumulator into the next call" do
    test_pid = self()

    step = fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})

      {:pass,
       %{
         acc
         | total_commands: acc.total_commands + 10,
           fires: Map.update(acc.fires, :check, 1, &(&1 + 1)),
           last_run: %{run_number: run_number}
       }}
    end

    assert {:ok, stats} = Campaign.loop(context(step, max_runs: 3), acc())

    calls = seen_runs()
    assert Enum.map(calls, &elem(&1, 0)) == [0, 1, 2]
    assert Enum.map(calls, fn {_, seen} -> seen.total_commands end) == [0, 10, 20]
    assert Enum.map(calls, fn {_, seen} -> seen.fires end) == [%{}, %{check: 1}, %{check: 2}]

    assert Enum.map(calls, fn {_, seen} -> seen.last_run end) == [
             nil,
             %{run_number: 0},
             %{run_number: 1}
           ]

    assert stats.total_commands == 30
    assert stats.check_fires == %{check: 3}
  end

  test "a context with a replay marks a passing run as not reproduced" do
    replay = %{sequence: nil, expansion: nil}
    ctx = context(passing_step(self()), first_run: 0, max_runs: 1, replay: replay)

    assert {:ok, stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0]
    assert stats.replay == :not_reproduced
  end

  describe "latency budget" do
    defp timed_acc(elapsed_us) do
      sample = %{"fake" => %{timings: [{FakeCommand, elapsed_us}]}}

      %{
        acc()
        | samples: [sample],
          last_run: %{
            sequence: %PropertyDamage.Sequence{},
            run_seed: 7,
            run_number: 0,
            results: [%{}]
          }
      }
    end

    defp latency_ctx(budget_ms) do
      context(passing_step(self()),
        max_runs: 1,
        latency: true,
        latency_budget: [warmup: 0, p95: [max: {budget_ms, :milliseconds}]]
      )
    end

    test "a sample under the budget finishes with the metrics in the stats" do
      assert {:ok, stats} = Campaign.loop(latency_ctx(10), timed_acc(5_000))

      assert stats.metrics["fake"].commands == 1
      assert stats.metrics["fake"].p95 == 5_000
    end

    test "a sample over the budget returns a latency report instead of stats" do
      assert {:error, %FailureReport{} = report} =
               Campaign.loop(latency_ctx(10), timed_acc(50_000))

      assert report.report_kind == :latency_exceeded
      assert report.variant == %{name: "fake", index: 0}
    end
  end
end
