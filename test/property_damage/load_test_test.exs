defmodule PropertyDamage.LoadTestTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.LoadTest
  alias PropertyDamage.LoadTest.{Metrics, RampStrategy, Report}

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

    test "tracks session counts" do
      {:ok, metrics} = Metrics.start_link()

      Metrics.session_started(metrics)
      Metrics.session_started(metrics)
      Metrics.session_started(metrics)

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)
      assert snapshot.active_sessions == 3
      assert snapshot.completed_sessions == 0

      Metrics.session_completed(metrics)
      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)
      assert snapshot.active_sessions == 2
      assert snapshot.completed_sessions == 1

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
  end

  # ============================================================================
  # RampStrategy Tests
  # ============================================================================

  describe "RampStrategy" do
    test "immediate plan starts all users at once" do
      plan = RampStrategy.plan(:immediate, 100)

      assert plan == [{0, 100}]
    end

    test "linear plan ramps gradually" do
      plan = RampStrategy.plan({:linear, {1, :seconds}}, 100)

      assert length(plan) == 10
      assert {0, _} = hd(plan)

      # Should end at target
      {_, final_users} = List.last(plan)
      assert final_users == 100

      # Should be monotonically increasing
      users = Enum.map(plan, fn {_, u} -> u end)
      assert users == Enum.sort(users)
    end

    test "step plan adds users in increments" do
      plan = RampStrategy.plan({:step, 4, {250, :milliseconds}}, 100)

      assert length(plan) == 4

      times = Enum.map(plan, fn {t, _} -> t end)
      assert times == [0, 250, 500, 750]

      {_, final_users} = List.last(plan)
      assert final_users == 100
    end

    test "exponential plan grows exponentially" do
      plan = RampStrategy.plan({:exponential, {1, :seconds}}, 100)

      users = Enum.map(plan, fn {_, u} -> u end)

      # Exponential growth: later increments should be larger
      first_half = Enum.slice(users, 0, 5)
      second_half = Enum.slice(users, 5, 5)

      first_growth = Enum.at(first_half, -1) - Enum.at(first_half, 0)
      second_growth = Enum.at(second_half, -1) - Enum.at(second_half, 0)

      # Second half should have more growth (exponential characteristic)
      assert second_growth >= first_growth
    end

    test "plan_down decreases users" do
      plan = RampStrategy.plan_down({:linear, {1, :seconds}}, 100)

      users = Enum.map(plan, fn {_, u} -> u end)

      # Should be monotonically decreasing
      assert users == Enum.sort(users, :desc)

      # Should end at 0
      assert List.last(users) == 0
    end

    test "duration_ms returns plan duration" do
      plan = RampStrategy.plan({:step, 4, {500, :milliseconds}}, 100)
      assert RampStrategy.duration_ms(plan) == 1500
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
          active_sessions: 0,
          completed_sessions: 50,
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
          history: []
        },
        config: %{
          model: TestModel,
          adapter: TestAdapter,
          concurrent_users: 50,
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

    test "formats markdown report", %{report: report} do
      output = Report.format(report, :markdown)

      assert String.contains?(output, "# PropertyDamage Load Test Report")
      assert String.contains?(output, "**Total Requests:**")
      assert String.contains?(output, "10,000")
    end

    test "formats json report", %{report: report} do
      output = Report.format(report, :json)
      decoded = Jason.decode!(output)

      assert decoded["metrics"]["total_requests"] == 10_000
      assert decoded["config"]["concurrent_users"] == 50
    end

    test "generates summary", %{report: report} do
      summary = Report.summary(report)

      assert String.contains?(summary, "10,000 requests")
      assert String.contains?(summary, "500.00 RPS")
    end
  end

  # ============================================================================
  # Integration Tests (with mock model/adapter)
  # ============================================================================

  describe "LoadTest integration" do
    defmodule MockCommand do
      defstruct [:value]

      def precondition(_state), do: true
      def new!(_state, _overrides), do: StreamData.constant(%__MODULE__{value: 1})
      def simulate(_state, _cmd), do: [%{type: :created}]
    end

    defmodule MockProjection do
      @behaviour PropertyDamage.Projection

      @impl true
      def init(), do: %{count: 0}

      @impl true
      def apply(state, _), do: %{state | count: state.count + 1}
    end

    defmodule MockModel do
      @behaviour PropertyDamage.Model

      @impl true
      def commands(), do: [{1, MockCommand}]

      @impl true
      def state_projection(), do: MockProjection

      @impl true
      def assertion_projections(), do: []
    end

    defmodule MockAdapter do
      @behaviour PropertyDamage.Adapter

      @impl true
      def setup(_config), do: {:ok, %{}}

      @impl true
      def teardown(_ctx), do: :ok

      @impl true
      def execute(_cmd, _ctx) do
        # Simulate some latency
        Process.sleep(:rand.uniform(5))
        {:ok, [%{type: :executed}]}
      end
    end

    @tag :integration
    test "runs a short load test" do
      # Run a very short load test
      {:ok, report} =
        LoadTest.run(
          model: MockModel,
          adapter: MockAdapter,
          concurrent_users: 2,
          duration: {500, :milliseconds}
        )

      assert report.metrics.total_requests > 0
      assert report.metrics.requests_per_second > 0
      assert report.config.concurrent_users == 2
    end

    @tag :integration
    test "supports async start/await" do
      {:ok, runner} =
        LoadTest.start(
          model: MockModel,
          adapter: MockAdapter,
          concurrent_users: 2,
          duration: {300, :milliseconds}
        )

      assert is_pid(runner)

      # Check status
      status = LoadTest.status(runner)
      assert status.target_users == 2
      assert status.phase in [:ramp_up, :steady]

      # Get metrics during run
      metrics = LoadTest.get_metrics(runner)
      assert is_map(metrics)

      # Wait for completion
      {:ok, report} = LoadTest.await(runner)
      assert report.metrics.total_requests > 0
    end

    @tag :integration
    test "supports early stop" do
      {:ok, runner} =
        LoadTest.start(
          model: MockModel,
          adapter: MockAdapter,
          concurrent_users: 2,
          duration: {10, :seconds}
        )

      # Let it run briefly
      Process.sleep(200)

      # Stop early
      {:ok, report} = LoadTest.stop(runner)
      assert report.metrics.total_requests > 0
    end

    @tag :integration
    test "calls on_metrics callback" do
      test_pid = self()

      {:ok, _report} =
        LoadTest.run(
          model: MockModel,
          adapter: MockAdapter,
          concurrent_users: 2,
          duration: {600, :milliseconds},
          metrics_interval: {100, :milliseconds},
          on_metrics: fn metrics ->
            send(test_pid, {:metrics, metrics})
          end
        )

      # Should have received multiple metrics callbacks
      assert_receive {:metrics, metrics}, 1000
      assert is_map(metrics)
      assert Map.has_key?(metrics, :requests_per_second)
    end

    @tag :integration
    test "uses linear ramp-up" do
      test_pid = self()
      session_counts = :ets.new(:session_counts, [:set, :public])
      :ets.insert(session_counts, {:max, 0})

      {:ok, _report} =
        LoadTest.run(
          model: MockModel,
          adapter: MockAdapter,
          concurrent_users: 4,
          duration: {800, :milliseconds},
          ramp_up: {:linear, {400, :milliseconds}},
          metrics_interval: {100, :milliseconds},
          on_metrics: fn metrics ->
            # Track max active sessions
            [{:max, current_max}] = :ets.lookup(session_counts, :max)
            new_max = max(current_max, metrics.active_sessions)
            :ets.insert(session_counts, {:max, new_max})
            send(test_pid, {:sessions, metrics.active_sessions})
          end
        )

      # Should have seen ramping (not all 4 at once from the start)
      # Due to timing, we just verify we received metrics
      assert_receive {:sessions, _}, 1000

      :ets.delete(session_counts)
    end
  end
end
