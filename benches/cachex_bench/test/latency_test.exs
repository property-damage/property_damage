defmodule CachexBench.CountingAdapter do
  @moduledoc false
  # Delegates to the real adapter and counts `setup/1` and `execute/3` calls in
  # the named Agent that `CachexBench.LatencyTest` starts for each test.
  use PropertyDamage.Adapter

  @impl true
  def setup(config) do
    Agent.update(CachexBench.LatencyTest.Counts, &Map.update(&1, :setups, 1, fn n -> n + 1 end))
    CachexBench.Adapter.setup(config)
  end

  @impl true
  def teardown(context), do: CachexBench.Adapter.teardown(context)

  @impl true
  def execute(command, context, runtime) do
    Agent.update(CachexBench.LatencyTest.Counts, &Map.update(&1, :executes, 1, fn n -> n + 1 end))
    CachexBench.Adapter.execute(command, context, runtime)
  end
end

defmodule CachexBench.LatencyTest do
  # Two Cachex targets run in lockstep and the run measures each target's
  # command latency. `CachexBench.Adapter` names a fresh cache on every
  # `setup/1`, so the two targets need no `config:` to keep their state apart.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PropertyDamage.FailureReport

  @seed 20_261_006
  @metric_keys [:by_command, :commands, :max, :mean, :min, :p50, :p95, :p99]

  setup do
    start_supervised!(%{
      id: CachexBench.LatencyTest.Counts,
      start: {Agent, :start_link, [fn -> %{} end, [name: CachexBench.LatencyTest.Counts]]}
    })

    :ok
  end

  defp pair(adapter \\ CachexBench.Adapter) do
    [{adapter, name: "a"}, {adapter, name: "b"}]
  end

  defp run(targets, opts) do
    PropertyDamage.run(
      [model: CachexBench.Model, targets: targets, max_runs: 5, max_commands: 20, seed: @seed] ++
        opts
    )
  end

  defp count(key), do: Agent.get(CachexBench.LatencyTest.Counts, &Map.get(&1, key, 0))
  defp reset_counts, do: Agent.update(CachexBench.LatencyTest.Counts, fn _ -> %{} end)

  test "latency: true passes and reports the metrics of both targets" do
    assert {:ok, stats} = run(pair(), latency: true)
    assert Enum.sort(Map.keys(stats.metrics)) == ["a", "b"]

    for name <- ["a", "b"] do
      assert Enum.sort(Map.keys(stats.metrics[name])) == @metric_keys
      assert stats.metrics[name].commands > 0
    end
  end

  test "verbose output prints the side-by-side table" do
    output = capture_io(fn -> assert {:ok, _} = run(pair(), latency: true, verbose: true) end)

    assert output =~ ~r/variant \(us\)\s+a\s+b/
    assert output =~ ~r/^\s*p95\s+[\d.]+\s+[\d.]+\s*$/m
  end

  test "a planted ratio fails with a latency report and re-executes nothing" do
    assert {:ok, _} = run(pair(CachexBench.CountingAdapter), latency: true)
    passing_executes = count(:executes)
    passing_setups = count(:setups)
    assert passing_executes > 0
    reset_counts()

    assert {:error, %FailureReport{} = report} =
             run(pair(CachexBench.CountingAdapter), latency: [p95: [max_ratio: 1.0e-9]])

    assert report.kind == :latency_exceeded
    assert report.shrink_iterations == 0
    assert report.variant.name == "b"
    assert Enum.sort(Map.keys(report.metrics)) == ["a", "b"]

    for name <- ["a", "b"], key <- [:p50, :p95, :p99] do
      assert is_number(report.metrics[name][key])
    end

    assert count(:executes) == passing_executes
    assert count(:setups) == passing_setups
  end

  test "a generous ratio passes, so the planted ratio is what fails the run" do
    assert {:ok, _} = run(pair(), latency: [p95: [max_ratio: 1.0e9]])
  end

  test "latency: true with concurrency: :parallel is an option error naming latency" do
    error =
      assert_raise NimbleOptions.ValidationError, fn ->
        run(pair(), latency: true, concurrency: :parallel)
      end

    assert Exception.message(error) =~ "latency"
  end

  test "compare: :performance is an option error naming latency:" do
    error =
      assert_raise NimbleOptions.ValidationError, fn ->
        run(pair(), compare: :performance)
      end

    assert Exception.message(error) =~ "latency:"
  end

  test "one target passes a max bound that it meets" do
    assert {:ok, stats} =
             run([CachexBench.Adapter], latency: [p99: [max: {1, :minutes}]])

    assert Map.keys(stats.metrics) == ["Adapter"]
  end

  test "one target with a max_ratio bound fails at run start before any setup" do
    error =
      assert_raise NimbleOptions.ValidationError, fn ->
        run([CachexBench.CountingAdapter], latency: [p95: [max_ratio: 1.5]])
      end

    assert Exception.message(error) =~ "at least two targets"
    assert count(:setups) == 0
  end
end
