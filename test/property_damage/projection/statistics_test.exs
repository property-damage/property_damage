defmodule PropertyDamage.Model.Projection.StatisticsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model.Projection.Statistics

  defmodule OrderCreated do
    defstruct [:latency_ms]
  end

  defmodule PaymentFailed do
    defstruct [:duration_ms]
  end

  defmodule Ping do
    defstruct []
  end

  defp with_latencies(state, latencies) do
    Enum.reduce(latencies, state, &Statistics.record_latency(&2, &1))
  end

  describe "init/0 and new/1" do
    test "init/0 builds an empty state with the default window" do
      assert %Statistics{window_size: 100, success_count: 0, error_count: 0, current_step: 0} =
               Statistics.init()
    end

    test "new/1 reads the window size" do
      assert %Statistics{window_size: 3} = Statistics.new(window_size: 3)
    end
  end

  describe "compute_metrics/1" do
    test "an empty state reports zero latency, a perfect success rate and no errors" do
      metrics = Statistics.compute_metrics(Statistics.init())

      assert metrics.p99_latency_ms == 0
      assert metrics.max_latency_ms == 0
      assert metrics.mean_latency_ms == 0
      assert metrics.success_rate == 1.0
      assert metrics.error_rate == 0.0
      assert metrics.total_count == 0
    end

    test "percentiles, max and mean come from the recorded samples" do
      metrics = Statistics.init() |> with_latencies(1..100) |> Statistics.compute_metrics()

      assert metrics.p50_latency_ms == 50
      assert metrics.p95_latency_ms == 95
      assert metrics.p99_latency_ms == 99
      assert metrics.max_latency_ms == 100
      assert metrics.mean_latency_ms == 50.5
      assert metrics.sample_count == 100
    end

    test "rates divide successes and errors by the total" do
      metrics =
        Statistics.init()
        |> Statistics.record_success()
        |> Statistics.record_success()
        |> Statistics.record_success()
        |> Statistics.record_error()
        |> Statistics.compute_metrics()

      assert metrics.success_rate == 0.75
      assert metrics.error_rate == 0.25
      assert metrics.total_count == 4
    end
  end

  describe "record_latency/2" do
    test "keeps only the newest window_size samples" do
      metrics =
        Statistics.new(window_size: 3)
        |> with_latencies([100, 1, 2, 3])
        |> Statistics.compute_metrics()

      assert metrics.sample_count == 3
      assert metrics.max_latency_ms == 3
    end
  end

  describe "apply/2" do
    test "records the latency_ms and duration_ms of an event and classifies its outcome" do
      state =
        Statistics.init()
        |> Statistics.apply(%OrderCreated{latency_ms: 40})
        |> Statistics.apply(%PaymentFailed{duration_ms: 90})

      metrics = Statistics.compute_metrics(state)

      assert metrics.sample_count == 2
      assert metrics.max_latency_ms == 90
      assert metrics.success_rate == 0.5
      assert metrics.error_rate == 0.5
      assert state.current_step == 2
    end

    test "counts an unclassified struct and a non-struct item as a step only" do
      state = Statistics.init() |> Statistics.apply(%Ping{}) |> Statistics.apply(:tick)

      assert state.current_step == 2
      assert Statistics.compute_metrics(state).total_count == 0
    end
  end

  describe "summary/1 and format_summary/1" do
    setup do
      state =
        Statistics.init()
        |> with_latencies([10, 20, 30])
        |> Statistics.record_success()
        |> Statistics.record_error()

      {:ok, state: state}
    end

    test "summary/1 groups latency, rates and counts", %{state: state} do
      summary = Statistics.summary(state)

      assert summary.latency.max == 30
      assert summary.rates == %{success: 0.5, error: 0.5}
      assert summary.counts == %{total: 2, success: 1, error: 1, latency_samples: 3}
    end

    test "format_summary/1 prints the rates as percentages", %{state: state} do
      text = Statistics.format_summary(state)

      assert text =~ "Statistics Summary:"
      assert text =~ "success=50.0% error=50.0%"
      assert text =~ "total=2 samples=3"
    end
  end

  test "the module declares no checks of its own" do
    assert Statistics.__checks__() == []
  end
end
