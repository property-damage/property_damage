defmodule PropertyDamage.LoadTestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # Module-function telemetry handler (avoids the local-function performance
  # warning telemetry logs for anonymous handlers).
  def forward_telemetry(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  alias PropertyDamage.LoadTest
  alias PropertyDamage.LoadTest.{Metrics, RampStrategy, Report, Worker, WorkerPool}
  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{LoadResult, LoadUpdate}

  # ============================================================================
  # Metrics Tests
  # ============================================================================

  describe "Metrics" do
    test "starts and stops" do
      {:ok, metrics} = Metrics.start_link()
      assert is_pid(metrics)
      assert :ok = Metrics.stop(metrics)
    end

    test "records requests and calculates stats" do
      {:ok, metrics} = Metrics.start_link()

      # Record some requests
      for _ <- 1..100 do
        latency = :rand.uniform(100)
        Metrics.record_request(metrics, TestCommand, latency, :ok)
      end

      # Wait for async processing
      Process.sleep(50)

      snapshot = Metrics.snapshot(metrics)

      assert snapshot.total_requests == 100
      assert snapshot.total_errors == 0
      assert snapshot.error_rate == 0.0
      assert snapshot.latency_p50 > 0
      assert snapshot.latency_p95 >= snapshot.latency_p50
      assert snapshot.requests_per_second > 0

      Metrics.stop(metrics)
    end

    test "tracks errors by type" do
      {:ok, metrics} = Metrics.start_link()

      Metrics.record_request(metrics, TestCommand, 10, :ok)
      Metrics.record_request(metrics, TestCommand, 10, {:error, :timeout})
      Metrics.record_request(metrics, TestCommand, 10, {:error, :timeout})
      Metrics.record_request(metrics, TestCommand, 10, {:error, :connection_error})

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)

      assert snapshot.total_requests == 4
      assert snapshot.total_errors == 3
      assert snapshot.errors_by_type[:timeout] == 2
      assert snapshot.errors_by_type[:connection_error] == 1

      Metrics.stop(metrics)
    end

    test "tracks arrival counts" do
      {:ok, metrics} = Metrics.start_link()

      Metrics.arrival_spawned(metrics)
      Metrics.arrival_spawned(metrics)
      Metrics.arrival_spawned(metrics)

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)
      assert snapshot.arrivals_spawned == 3
      assert snapshot.arrivals_completed == 0

      Metrics.arrival_completed(metrics)
      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)
      assert snapshot.arrivals_spawned == 3
      assert snapshot.arrivals_completed == 1

      Metrics.stop(metrics)
    end

    test "tracks per-command metrics" do
      {:ok, metrics} = Metrics.start_link()

      for i <- 1..50 do
        Metrics.record_request(metrics, CreateAccount, i * 2, :ok)
        Metrics.record_request(metrics, GetBalance, i, :ok)
      end

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)

      assert snapshot.by_command[CreateAccount].count == 50
      assert snapshot.by_command[GetBalance].count == 50

      assert snapshot.by_command[CreateAccount].latency_mean >
               snapshot.by_command[GetBalance].latency_mean

      Metrics.stop(metrics)
    end

    test "resets metrics" do
      {:ok, metrics} = Metrics.start_link()

      for _ <- 1..10 do
        Metrics.record_request(metrics, TestCommand, 10, :ok)
      end

      Process.sleep(50)
      Metrics.reset(metrics)
      snapshot = Metrics.snapshot(metrics)

      assert snapshot.total_requests == 0
      assert map_size(snapshot.by_command) == 0

      Metrics.stop(metrics)
    end

    test "tracks assertion failures" do
      {:ok, metrics} = Metrics.start_link()

      # Record some assertion failures (by exception module)
      Metrics.record_assertion_failure(metrics, PropertyDamage.AssertionFailed, CreateAccount, %{
        reason: "balance -50",
        command_index: 5,
        step_type: :command,
        module: CreateAccount,
        timestamp: System.monotonic_time(:millisecond)
      })

      Metrics.record_assertion_failure(metrics, PropertyDamage.AssertionFailed, CreateAccount, %{
        reason: "balance -100",
        command_index: 10,
        step_type: :event,
        module: AccountCreated,
        timestamp: System.monotonic_time(:millisecond)
      })

      Metrics.record_assertion_failure(metrics, ArgumentError, DeleteAccount, %{
        reason: "orphaned order",
        command_index: 15,
        step_type: :command,
        module: DeleteAccount,
        timestamp: System.monotonic_time(:millisecond)
      })

      # Also record some requests
      for _ <- 1..100 do
        Metrics.record_request(metrics, TestCommand, 10, :ok)
      end

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)

      assert snapshot.assertion_failures == 3
      assert snapshot.assertion_failure_rate == 3.0
      assert snapshot.failures_by_exception[PropertyDamage.AssertionFailed] == 2
      assert snapshot.failures_by_exception[ArgumentError] == 1
      assert length(snapshot.recent_assertion_failures) == 3

      # Verify failure details
      [first | _] = snapshot.recent_assertion_failures
      assert first.exception_module in [PropertyDamage.AssertionFailed, ArgumentError]
      assert Map.has_key?(first, :reason)
      assert Map.has_key?(first, :command_index)

      Metrics.stop(metrics)
    end

    test "bounds recent assertion failures" do
      {:ok, metrics} = Metrics.start_link()

      # Record more failures than the max (100)
      for i <- 1..150 do
        Metrics.record_assertion_failure(metrics, PropertyDamage.AssertionFailed, TestCommand, %{
          reason: "failure #{i}",
          command_index: i,
          step_type: :command,
          module: TestCommand,
          timestamp: System.monotonic_time(:millisecond)
        })
      end

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)

      # Total count should be all failures
      assert snapshot.assertion_failures == 150

      # But recent failures should be bounded
      assert length(snapshot.recent_assertion_failures) <= 100

      Metrics.stop(metrics)
    end
  end

  # ============================================================================
  # RampStrategy Tests
  # ============================================================================

  describe "RampStrategy" do
    test "immediate plan starts at target rate at once" do
      target_rate = {100, {1, :seconds}}
      plan = RampStrategy.plan(:immediate, target_rate)

      assert plan == [{0, target_rate}]
    end

    test "linear plan ramps gradually" do
      target_rate = {100, {1, :seconds}}
      plan = RampStrategy.plan({:linear, {1, :seconds}}, target_rate)

      assert length(plan) == 10
      assert {0, _} = hd(plan)

      # Should end at target (100/sec)
      {_, {final_rate, {1, :seconds}}} = List.last(plan)
      assert final_rate == 100

      # Should be monotonically increasing
      rates = Enum.map(plan, fn {_, {r, _}} -> r end)
      assert rates == Enum.sort(rates)
    end

    test "step plan increases rate in increments" do
      target_rate = {100, {1, :seconds}}
      plan = RampStrategy.plan({:step, 4, {250, :milliseconds}}, target_rate)

      assert length(plan) == 4

      times = Enum.map(plan, fn {t, _} -> t end)
      assert times == [0, 250, 500, 750]

      {_, {final_rate, _}} = List.last(plan)
      assert final_rate == 100
    end

    test "exponential plan grows exponentially" do
      target_rate = {100, {1, :seconds}}
      plan = RampStrategy.plan({:exponential, {1, :seconds}}, target_rate)

      rates = Enum.map(plan, fn {_, {r, _}} -> r end)

      # Exponential growth: later increments should be larger
      first_half = Enum.slice(rates, 0, 5)
      second_half = Enum.slice(rates, 5, 5)

      first_growth = Enum.at(first_half, -1) - Enum.at(first_half, 0)
      second_growth = Enum.at(second_half, -1) - Enum.at(second_half, 0)

      # Second half should have more growth (exponential characteristic)
      assert second_growth >= first_growth
    end

    test "plan_down decreases rate" do
      current_rate = {100, {1, :seconds}}
      plan = RampStrategy.plan_down({:linear, {1, :seconds}}, current_rate)

      rates = Enum.map(plan, fn {_, {r, _}} -> r end)

      # Should be monotonically decreasing
      assert rates == Enum.sort(rates, :desc)

      # Should end at minimum (1/sec)
      assert List.last(rates) == 1
    end

    test "duration_ms returns plan duration" do
      target_rate = {100, {1, :seconds}}
      plan = RampStrategy.plan({:step, 4, {500, :milliseconds}}, target_rate)
      assert RampStrategy.duration_ms(plan) == 1500
    end

    test "rate_to_per_second converts rate specs" do
      # 100 per second
      assert RampStrategy.rate_to_per_second({100, {1, :seconds}}) == 100.0

      # 2 per 15 milliseconds = 133.33/sec
      rate = RampStrategy.rate_to_per_second({2, {15, :milliseconds}})
      assert_in_delta rate, 133.33, 0.1

      # 60 per minute = 1/sec
      assert RampStrategy.rate_to_per_second({60, {1, :minutes}}) == 1.0
    end

    test "rate_to_interval_ms converts rate to interval" do
      # 100 per second = 10ms interval
      assert RampStrategy.rate_to_interval_ms({100, {1, :seconds}}) == 10.0

      # 2 per 20 ms = 10ms interval
      assert RampStrategy.rate_to_interval_ms({2, {20, :milliseconds}}) == 10.0

      # 1 per second = 1000ms interval
      assert RampStrategy.rate_to_interval_ms({1, {1, :seconds}}) == 1000.0
    end
  end

  # ============================================================================
  # Report Tests
  # ============================================================================

  describe "Report" do
    setup do
      report = %{
        metrics: %{
          total_requests: 10_000,
          requests_per_second: 500.0,
          latency_p50: 12.5,
          latency_p95: 45.2,
          latency_p99: 89.7,
          latency_max: 250.0,
          latency_min: 2.1,
          latency_mean: 18.3,
          total_errors: 15,
          error_rate: 0.15,
          errors_by_type: %{timeout: 10, connection_error: 5},
          arrivals_spawned: 10_000,
          arrivals_completed: 10_000,
          arrivals_per_second: 166.67,
          by_command: %{
            CreateAccount => %{
              count: 5000,
              latency_p50: 10.0,
              latency_p95: 40.0,
              latency_mean: 15.0,
              error_count: 5
            },
            GetBalance => %{
              count: 5000,
              latency_p50: 5.0,
              latency_p95: 20.0,
              latency_mean: 8.0,
              error_count: 10
            }
          },
          duration_ms: 60_000,
          history: [],
          assertion_failures: 0,
          assertion_failure_rate: 0.0,
          failures_by_exception: %{},
          recent_assertion_failures: []
        },
        pool_stats: %{
          total_created: 50,
          peak_in_use: 45,
          utilization: 0.85,
          peak_utilization: 0.90,
          avg_utilization: 0.80,
          total_checkouts: 10_000
        },
        config: %{
          model: TestModel,
          adapter: TestAdapter,
          arrival_rate: {100, {1, :seconds}},
          duration_ms: 60_000
        }
      }

      {:ok, report: report}
    end

    test "formats terminal report", %{report: report} do
      output = Report.format(report, :terminal)

      assert String.contains?(output, "PROPERTY DAMAGE LOAD TEST REPORT")
      assert String.contains?(output, "10,000")
      assert String.contains?(output, "500.00")
      assert String.contains?(output, "45.20")
    end

    # Regression: the ascii throughput chart iterates a descending range
    # `(height - 1)..0`, whose implicit step is deprecated on Elixir 1.18 and
    # errors under --warnings-as-errors. With a populated history the chart path
    # runs; format/2 must return a binary without raising.
    test "renders the ascii throughput chart over a populated history", %{report: report} do
      history = for i <- 1..12, do: %{rps: i * 50.0}
      report = put_in(report.metrics.history, history)

      output = Report.format(report, :terminal)

      assert is_binary(output)
      assert String.contains?(output, "Throughput Over Time")
    end

    test "formats markdown report", %{report: report} do
      output = Report.format(report, :markdown)

      assert String.contains?(output, "# PropertyDamage Load Test Report")
      assert String.contains?(output, "**Total Commands:**")
      assert String.contains?(output, "10,000")
    end

    test "formats json report", %{report: report} do
      output = Report.format(report, :json)
      decoded = Jason.decode!(output)

      assert decoded["metrics"]["total_requests"] == 10_000
      assert decoded["config"]["arrival_rate"] == [100, [1, "seconds"]]
    end

    test "generates summary", %{report: report} do
      summary = Report.summary(report)

      assert String.contains?(summary, "10,000 commands")
      assert String.contains?(summary, "500.00 cmd/sec")
    end
  end

  # ============================================================================
  # Worker and WorkerPool Test Fixtures
  # ============================================================================

  defmodule WorkerTestCommand do
    defstruct [:value]

    def generator(_overrides \\ %{}), do: StreamData.constant(%{value: 1})
  end

  defmodule WorkerTestProjection do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, _), do: %{state | count: state.count + 1}
  end

  defmodule WorkerTestModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl PropertyDamage.Model
    def commands, do: [WorkerTestCommand]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: WorkerTestProjection

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(_cmd, _state), do: [%{type: :created}]

    @impl PropertyDamage.Model
    def assertion_projections, do: []
  end

  defmodule WorkerTestAdapter do
    use PropertyDamage.Adapter, default_timeout: 30

    @impl true
    def setup(_config), do: {:ok, %{setup_at: System.monotonic_time()}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, _ctx, _runtime) do
      Process.sleep(:rand.uniform(5))
      {:ok, [%{type: :executed}]}
    end
  end

  # Characterization support (F2 sink-window refactor): an adapter that injects
  # mid-execution. The worker's inject closure captures the per-command sink pid
  # so it accumulates from inside the spawned timeout Task (DR-027); a regression
  # that breaks the sink boundary makes inject raise "outside adapter execution
  # context", surfacing as a command error in the worker's metrics.
  defmodule WorkerInjectingAdapter do
    use PropertyDamage.Adapter, default_timeout: 30

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, _ctx, runtime) do
      runtime.inject.(%{type: :injected})
      {:ok, [%{type: :executed}]}
    end
  end

  # Ordering-regression fixtures: a command whose event sets state the command's
  # own `@trigger` reads back. Under load-test assertions this must observe the
  # command's own event (matching the main Executor), so `last` is set when the
  # command-level assertion fires. If the worker asserted before folding the
  # command's events, `last` would still be nil and every command would fail.
  defmodule OrderingEvent do
    defstruct [:n]
  end

  defmodule OrderingCommand do
    defstruct [:n]

    def generator(_overrides \\ %{}), do: StreamData.constant(%{n: 1})
  end

  defmodule OrderingProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{last: nil}

    @impl true
    def apply(state, %OrderingEvent{n: n}), do: %{state | last: n}
    def apply(state, _), do: state

    @trigger every: PropertyDamage.LoadTestTest.OrderingCommand
    def assert_sees_own_event(state, _cmd) do
      if state.last == nil do
        PropertyDamage.fail!(
          "command-level assertion ran before the command's own event was folded"
        )
      end
    end
  end

  defmodule OrderingModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl PropertyDamage.Model
    def commands, do: [PropertyDamage.LoadTestTest.OrderingCommand]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: PropertyDamage.LoadTestTest.OrderingProjection

    @impl PropertyDamage.Model
    def assertion_projections, do: [PropertyDamage.LoadTestTest.OrderingProjection]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%PropertyDamage.LoadTestTest.OrderingCommand{}, _state),
      do: [%PropertyDamage.LoadTestTest.OrderingEvent{n: 1}]
  end

  defmodule OrderingAdapter do
    use PropertyDamage.Adapter, default_timeout: 30

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, _ctx, _runtime),
      do: {:ok, [%PropertyDamage.LoadTestTest.OrderingEvent{n: 1}]}
  end

  # ============================================================================
  # Worker Tests
  # ============================================================================

  describe "Worker" do
    test "command-level assertions observe the command's own events (ordering regression)" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: OrderingModel,
          adapter: OrderingAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :record
        )

      assert {:ok, stats} = Worker.execute_sequence(worker)
      assert stats.commands_run >= 1

      # The command's `@trigger` read its own event, so nothing failed. Before the
      # worker folded events before command assertions, each command failed here.
      assert stats.assertion_failures == 0

      Process.sleep(20)
      assert Metrics.snapshot(metrics).assertion_failures == 0

      Worker.stop(worker)
      Metrics.stop(metrics)
    end

    test "starts with persistent adapter context" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: WorkerTestModel,
          adapter: WorkerTestAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      assert is_pid(worker)

      Worker.stop(worker)
      Metrics.stop(metrics)
    end

    test "executes sequences using persistent context" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: WorkerTestModel,
          adapter: WorkerTestAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      # Execute a sequence
      result = Worker.execute_sequence(worker)
      assert {:ok, stats} = result
      assert is_map(stats)

      # Execute another sequence (should reuse context)
      result = Worker.execute_sequence(worker)
      assert {:ok, _} = result

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)
      assert snapshot.total_requests >= 2

      Worker.stop(worker)
      Metrics.stop(metrics)
    end

    test "an adapter that injects mid-execution runs without error (characterization)" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: WorkerTestModel,
          adapter: WorkerInjectingAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      assert {:ok, stats} = Worker.execute_sequence(worker)

      # The injecting adapter executes cleanly: every command ran and none errored.
      # If inject lost its sink across the spawned timeout Task, each command would
      # raise and be counted as an error here.
      assert stats.commands_run >= 1
      assert stats.errors == 0

      Worker.stop(worker)
      Metrics.stop(metrics)
    end
  end

  # ============================================================================
  # WorkerPool Tests
  # ============================================================================

  describe "WorkerPool" do
    test "starts empty dynamic pool" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, pool} =
        WorkerPool.start_link(
          model: WorkerTestModel,
          adapter: WorkerTestAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      stats = WorkerPool.stats(pool)
      assert stats.total_created == 0
      assert stats.available == 0
      assert stats.in_use == 0

      WorkerPool.stop(pool)
      Metrics.stop(metrics)
    end

    test "checkout creates workers on demand and checkin returns them" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, pool} =
        WorkerPool.start_link(
          model: WorkerTestModel,
          adapter: WorkerTestAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      # Checkout first worker - should create one
      {:ok, worker1} = WorkerPool.checkout(pool)
      assert is_pid(worker1)

      stats = WorkerPool.stats(pool)
      assert stats.total_created == 1
      assert stats.available == 0
      assert stats.in_use == 1

      # Checkout second worker - should create another
      {:ok, worker2} = WorkerPool.checkout(pool)
      assert worker1 != worker2

      stats = WorkerPool.stats(pool)
      assert stats.total_created == 2
      assert stats.available == 0
      assert stats.in_use == 2

      # Checkin first worker
      :ok = WorkerPool.checkin(pool, worker1)

      stats = WorkerPool.stats(pool)
      assert stats.available == 1
      assert stats.in_use == 1

      # Checkout again - should reuse the checked-in worker
      {:ok, worker3} = WorkerPool.checkout(pool)
      assert worker3 == worker1

      stats = WorkerPool.stats(pool)
      assert stats.total_created == 2
      assert stats.available == 0
      assert stats.in_use == 2

      WorkerPool.stop(pool)
      Metrics.stop(metrics)
    end

    test "tracks peak workers in use" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, pool} =
        WorkerPool.start_link(
          model: WorkerTestModel,
          adapter: WorkerTestAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      # Checkout 3 workers
      {:ok, w1} = WorkerPool.checkout(pool)
      {:ok, w2} = WorkerPool.checkout(pool)
      {:ok, w3} = WorkerPool.checkout(pool)

      stats = WorkerPool.stats(pool)
      assert stats.peak_in_use == 3

      # Return all workers
      WorkerPool.checkin(pool, w1)
      WorkerPool.checkin(pool, w2)
      WorkerPool.checkin(pool, w3)

      # Peak should still be 3
      stats = WorkerPool.stats(pool)
      assert stats.peak_in_use == 3
      assert stats.in_use == 0

      WorkerPool.stop(pool)
      Metrics.stop(metrics)
    end
  end

  # ============================================================================
  # Integration Tests (with mock model/adapter)
  # ============================================================================

  describe "LoadTest integration" do
    defmodule MockCommand do
      defstruct [:value]

      def generator(_overrides \\ %{}), do: StreamData.constant(%{value: 1})
    end

    defmodule MockProjection do
      @behaviour PropertyDamage.Model.Projection

      @impl true
      def init, do: %{count: 0}

      @impl true
      def apply(state, _), do: %{state | count: state.count + 1}
    end

    defmodule MockModel do
      @behaviour PropertyDamage.Model
      @behaviour PropertyDamage.Model.Simulator

      @impl PropertyDamage.Model
      def commands, do: [MockCommand]

      @impl PropertyDamage.Model
      def command_sequence_projection, do: MockProjection

      @impl PropertyDamage.Model
      def assertion_projections, do: []

      @impl PropertyDamage.Model
      def simulator, do: __MODULE__

      @impl PropertyDamage.Model.Simulator
      def simulate(_cmd, _state), do: [%{type: :created}]
    end

    defmodule MockAdapter do
      use PropertyDamage.Adapter, default_timeout: 30

      @impl true
      def setup(_config), do: {:ok, %{}}

      @impl true
      def teardown(_ctx), do: :ok

      @impl true
      def execute(_cmd, _ctx, _runtime) do
        # Simulate some latency
        Process.sleep(:rand.uniform(5))
        {:ok, [%{type: :executed}]}
      end
    end

    @tag :integration
    test "runs a short load test" do
      capture_log(fn ->
        # Run a very short load test
        {:ok, report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 50,
            duration: {500, :milliseconds}
          )

        assert report.metrics.total_requests > 0
        assert report.metrics.requests_per_second > 0
        assert report.config.arrival_rate == {50, {1, :seconds}}
      end)
    end

    @tag :integration
    test "supports async start/await" do
      capture_log(fn ->
        {:ok, runner} =
          LoadTest.start(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 50,
            duration: {300, :milliseconds}
          )

        assert is_pid(runner)

        # Check status
        status = LoadTest.status(runner)
        assert status.target_rate == {50, {1, :seconds}}
        assert status.phase in [:ramp_up, :steady]

        # Get metrics during run
        metrics = LoadTest.get_metrics(runner)
        assert is_map(metrics)

        # Wait for completion
        {:ok, report} = LoadTest.await(runner)
        assert report.metrics.total_requests > 0
      end)
    end

    @tag :integration
    test "supports early stop" do
      capture_log(fn ->
        {:ok, runner} =
          LoadTest.start(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 50,
            duration: {10, :seconds}
          )

        # Let it run briefly
        Process.sleep(200)

        # Stop early
        {:ok, report} = LoadTest.stop(runner)
        assert report.metrics.total_requests > 0
      end)
    end

    @tag :integration
    test "on_progress receives LoadUpdate snapshots and a terminal LoadResult" do
      test_pid = self()

      capture_log(fn ->
        {:ok, report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 50,
            duration: {600, :milliseconds},
            metrics_interval: {100, :milliseconds},
            # The consumer runs inside the notifier process, so it must forward
            # to the test pid rather than receive (which would read the
            # notifier's own mailbox).
            on_progress: fn progress -> send(test_pid, {:progress, progress}) end
          )

        # Periodic snapshots arrive as LoadUpdate progress values.
        assert_receive {:progress, %Progress{data: %LoadUpdate{snapshot: snapshot}}}, 1000
        assert is_map(snapshot)
        assert Map.has_key?(snapshot, :requests_per_second)

        # The terminal LoadResult carries a copy of the authoritative report.
        assert_receive {:progress, %Progress{data: %LoadResult{report: result_report}}}, 1000
        assert result_report == report
      end)
    end

    @tag :integration
    test "emits coarse load_test progress and result telemetry events" do
      parent = self()
      handler_id = "pd-load-progress-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:property_damage, :load_test, :progress], [:property_damage, :load_test, :result]],
        &__MODULE__.forward_telemetry/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log(fn ->
        LoadTest.run(
          model: MockModel,
          adapter: MockAdapter,
          arrival_rate: 50,
          duration: {400, :milliseconds},
          metrics_interval: {100, :milliseconds}
        )
      end)

      assert_receive {:telemetry, [:property_damage, :load_test, :progress], _m,
                      %{data: %LoadUpdate{}}},
                     1000

      assert_receive {:telemetry, [:property_damage, :load_test, :result], _m,
                      %{data: %LoadResult{}}},
                     1000
    end

    @tag :integration
    test "uses linear ramp-up" do
      test_pid = self()

      capture_log(fn ->
        {:ok, _report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 100,
            duration: {800, :milliseconds},
            ramp_up: {:linear, {400, :milliseconds}},
            metrics_interval: {100, :milliseconds},
            on_progress: fn
              %Progress{data: %LoadUpdate{snapshot: snapshot}} ->
                send(test_pid, {:arrivals, snapshot.arrivals_spawned})

              _ ->
                :ok
            end
          )

        # Should have seen ramping (not all at full rate from the start)
        assert_receive {:arrivals, _}, 1000
      end)
    end

    @tag :integration
    test "a slow on_progress consumer does not stall arrival scheduling" do
      test_pid = self()

      capture_log(fn ->
        # This consumer sleeps far longer than the metrics interval. Because the
        # load-test runner dispatches through an isolated notifier process, the
        # delay is absorbed there and never blocks the runner's arrival loop.
        {:ok, report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 100,
            duration: {500, :milliseconds},
            metrics_interval: {50, :milliseconds},
            on_progress: fn _progress ->
              Process.sleep(200)
              send(test_pid, :consumed)
            end
          )

        # Arrivals kept flowing despite the slow consumer (a stalled runner
        # would produce far fewer than the ~50 expected at 100/sec for 500ms).
        assert report.metrics.arrivals_spawned > 20,
               "slow consumer stalled load generation: only " <>
                 "#{report.metrics.arrivals_spawned} arrivals"

        # The terminal flush still delivers, even with a slow consumer.
        assert_receive :consumed, 2000
      end)
    end

    @tag :integration
    test "dynamic pool grows to handle high arrival rate" do
      capture_log(fn ->
        # Use high arrival rate - pool should grow dynamically to handle it
        {:ok, report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 200,
            duration: {300, :milliseconds}
          )

        # With dynamic pool, all arrivals should be handled (no drops)
        assert report.metrics.arrivals_spawned > 0

        # Pool stats should show workers were created
        assert report.pool_stats.total_created > 0
        assert report.pool_stats.peak_in_use > 0
      end)
    end

    # Model with assertion projections for testing assertion_mode option
    defmodule FailingAssertionProjection do
      use PropertyDamage.Model.Projection

      @impl true
      def init, do: %{count: 0}

      @impl true
      def apply(state, _), do: %{state | count: state.count + 1}

      @trigger every: 1
      def assert_count_check(state, _cmd_or_event) do
        # Fail every 3rd assertion to simulate intermittent failures
        if rem(state.count, 3) == 0 do
          PropertyDamage.fail!("count is divisible by 3", count: state.count)
        end
      end
    end

    defmodule MockModelWithAssertions do
      @behaviour PropertyDamage.Model

      @impl true
      def commands, do: [{MockCommand, weight: 1}]

      @impl true
      def command_sequence_projection, do: MockProjection

      @impl true
      def assertion_projections, do: [FailingAssertionProjection]
    end

    @tag :integration
    test "runs load test with assertions disabled (default)" do
      capture_log(fn ->
        {:ok, report} =
          LoadTest.run(
            model: MockModelWithAssertions,
            adapter: MockAdapter,
            arrival_rate: 50,
            duration: {500, :milliseconds}
          )

        # Should have requests but no assertion failures tracked
        # (because assertion_mode defaults to :disabled)
        assert report.metrics.total_requests > 0
        assert report.metrics.assertion_failures == 0
      end)
    end

    @tag :integration
    test "runs load test with assertions enabled and tracks failures" do
      capture_log(fn ->
        {:ok, report} =
          LoadTest.run(
            model: MockModelWithAssertions,
            adapter: MockAdapter,
            arrival_rate: 50,
            duration: {500, :milliseconds},
            assertion_mode: :record
          )

        # Should have requests and some assertion failures
        assert report.metrics.total_requests > 0

        # Since we fail every 3rd assertion, we should have failures
        assert report.metrics.assertion_failures > 0
        assert report.metrics.assertion_failure_rate > 0

        # Should have tracked failures by exception module
        assert Map.has_key?(report.metrics.failures_by_exception, PropertyDamage.AssertionFailed)
      end)
    end

    @tag :integration
    test "linear ramp produces single arrival chain (no rate multiplication)" do
      capture_log(fn ->
        # This test verifies the fix for the bug where each ramp step created
        # a new parallel arrival chain, causing rate multiplication.
        #
        # With linear ramp over 500ms to target rate 100/sec:
        # - 10 steps, each increasing rate by 10%
        # - Total duration: 500ms ramp + 500ms steady = 1000ms
        # - Expected arrivals (integral of ramp curve + steady):
        #   Ramp: avg rate ~55/sec for 500ms = ~27 arrivals
        #   Steady: 100/sec for 500ms = ~50 arrivals
        #   Total: ~77 arrivals
        #
        # With the bug (10 parallel chains): would be ~770 arrivals
        # Without the bug (single chain): ~77 arrivals

        {:ok, report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 100,
            duration: {1000, :milliseconds},
            ramp_up: {:linear, {500, :milliseconds}},
            ramp_down: :immediate
          )

        arrivals = report.metrics.arrivals_spawned

        # Sanity check: we should have a reasonable number of arrivals
        # Not 0 (broken), not 10x expected (bug), but roughly in the expected range
        #
        # Allow generous tolerance for timing variations, but catch the 10x bug
        # Expected ~77, allow 40-200 range to account for timing jitter
        assert arrivals > 30,
               "Expected at least 30 arrivals, got #{arrivals} - arrival chain may not be starting"

        assert arrivals < 250,
               "Expected fewer than 250 arrivals, got #{arrivals} - possible parallel arrival chain bug"

        # Additional sanity check: arrival rate should be reasonable
        test_duration_sec = report.metrics.duration_ms / 1000
        actual_rate = arrivals / test_duration_sec
        # With linear ramp, effective average rate is ~75% of target (0-100 over 50%, 100 for 50%)
        # So we expect roughly 75/sec average, allow 40-150 range
        assert actual_rate > 30,
               "Arrival rate too low: #{actual_rate}/sec"

        assert actual_rate < 150,
               "Arrival rate too high: #{actual_rate}/sec - possible parallel chain bug"
      end)
    end

    @tag :integration
    test "immediate ramp produces correct arrival rate" do
      capture_log(fn ->
        # With immediate ramp, rate should be at target from the start
        {:ok, report} =
          LoadTest.run(
            model: MockModel,
            adapter: MockAdapter,
            arrival_rate: 100,
            duration: {500, :milliseconds},
            ramp_up: :immediate,
            ramp_down: :immediate
          )

        arrivals = report.metrics.arrivals_spawned
        test_duration_sec = report.metrics.duration_ms / 1000

        # Expected: ~100/sec * 0.5sec = ~50 arrivals
        # Allow generous range for timing: 25-100
        assert arrivals > 20,
               "Expected at least 20 arrivals at 100/sec for 500ms, got #{arrivals}"

        assert arrivals < 100,
               "Expected fewer than 100 arrivals at 100/sec for 500ms, got #{arrivals}"

        # Verify rate is roughly correct
        actual_rate = arrivals / test_duration_sec

        assert_in_delta actual_rate,
                        100,
                        50,
                        "Arrival rate #{actual_rate}/sec not close to target 100/sec"
      end)
    end
  end
end
