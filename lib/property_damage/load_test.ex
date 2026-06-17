defmodule PropertyDamage.LoadTest do
  @moduledoc """
  Load testing with realistic SPBT-generated traffic.

  PropertyDamage.LoadTest leverages the stateful property-based testing
  infrastructure to generate realistic load against a system. Unlike
  synthetic benchmarks, each simulated user session follows valid state
  transitions with command weights that model real usage patterns.

  ## Key Benefits

  - **Realistic Traffic**: Commands respect preconditions and state
  - **Model-Based**: Same model used for correctness testing
  - **Metrics Collection**: Latency percentiles, throughput, errors
  - **Ramping Strategies**: Linear, step, exponential load curves
  - **Live Reporting**: Periodic metrics callbacks
  - **Dynamic Worker Pool**: Workers created on demand, no sizing needed
  - **Command Timeouts**: Prevents hung commands from causing unbounded growth

  ## Quick Start

      # Run a 2-minute load test at 100 arrivals/second
      {:ok, report} = PropertyDamage.LoadTest.run(
        model: MyApp.TestModel,
        adapter: MyApp.HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        arrival_rate: 100,
        duration: {2, :minutes}
      )

      # Print the report
      IO.puts(PropertyDamage.LoadTest.Report.format(report, :terminal))

  ## Advanced Usage

      {:ok, report} = PropertyDamage.LoadTest.run(
        model: MyApp.TestModel,
        adapter: MyApp.HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},

        # Load configuration
        arrival_rate: 100,  # 100 arrivals/second
        duration: {5, :minutes},

        # Ramp strategy - gradually increase load
        ramp_up: {:linear, {30, :seconds}},
        ramp_down: {:linear, {10, :seconds}},

        # Session behavior
        think_time: {100, 500},

        # Unified progress projection (DR-022): periodic LoadUpdate snapshots
        # and a terminal LoadResult carrying the final report.
        on_progress: fn
          %PropertyDamage.Progress{data: %PropertyDamage.Progress.LoadUpdate{snapshot: m}} ->
            IO.puts("RPS: \#{m.requests_per_second}, p95: \#{m.latency_p95}ms")

          %PropertyDamage.Progress{data: %PropertyDamage.Progress.LoadResult{report: report}} ->
            PropertyDamage.LoadTest.Report.save(report, "load_test.md", :markdown)
        end
      )

  ## Dynamic Worker Pool

  The worker pool grows automatically to meet arrival rate demand. Workers
  are created on demand when no idle workers are available, eliminating the
  need to calculate pool sizes. The pool tracks:

  - **Workers Created**: Total workers created during the test
  - **Peak Workers**: Maximum concurrent workers at any point
  - **Utilization**: How efficiently workers are being used

  ## Command Timeouts

  Adapters can specify timeouts for command execution via the `timeout/1`
  callback. This prevents hung commands from causing unbounded pool growth:

      defmodule MyAdapter do
        use PropertyDamage.Adapter, default_timeout: 30  # 30 seconds

        # Override for slow polling command
        def timeout(%CreateAuthorization{}), do: 120
      end

  Commands that exceed their timeout raise `PropertyDamage.CommandTimeoutError`.

  ## Ramp Strategies

  Control how load is applied over time:

  - `:immediate` - Start at full rate immediately
  - `{:linear, duration}` - Gradual linear ramp
  - `{:step, count, interval}` - Increase rate in steps
  - `{:exponential, duration}` - Exponential growth curve

  ## Metrics Collected

  - **Throughput**: Total requests, requests/second
  - **Latency**: p50, p95, p99, min, max, mean
  - **Errors**: Total count, error rate, by type
  - **Assertions**: Failures count, rate, by assertion name (when enabled)
  - **Per-Command**: Breakdown by command type
  - **Worker Pool**: Workers created, peak workers, utilization
  - **History**: Time series for trend analysis

  ## Architecture

  ```
  PropertyDamage.LoadTest
  ├── Runner         # Orchestrates arrivals and metrics
  ├── WorkerPool     # Dynamic pool of workers (auto-scaling)
  ├── Worker         # Holds adapter context, executes sequences
  ├── Metrics        # Collects latency, throughput, errors
  ├── RampStrategy   # Controls load ramping
  └── Report         # Generates load test reports
  ```
  """

  alias PropertyDamage.LoadTest.{Report, Runner}

  @type duration :: {pos_integer(), :milliseconds | :seconds | :minutes}

  @type ramp_strategy ::
          :immediate
          | {:linear, duration()}
          | {:step, pos_integer(), duration()}
          | {:exponential, duration()}

  @type report :: %{
          metrics: map(),
          config: map()
        }

  @doc """
  Run a load test.

  This is the main entry point for load testing. It starts concurrent
  user sessions that generate and execute command sequences against
  the system under test.

  ## Required Options

  - `:model` - Model module implementing PropertyDamage.Model
  - `:adapter` - Adapter module implementing PropertyDamage.Adapter
  - `:concurrent_users` - Target number of concurrent user sessions
  - `:duration` - Test duration as `{value, unit}` tuple

  ## Optional Options

  - `:adapter_config` - Configuration passed to adapter.setup/1 (default: %{})
  - `:ramp_up` - Strategy for ramping up load (default: :immediate)
  - `:ramp_down` - Strategy for ramping down load (default: :immediate)
  - `:commands_per_session` - {min, max} commands per sequence (default: {10, 50})
  - `:think_time` - {min, max} ms delay between commands (default: {0, 0})
  - `:metrics_interval` - Snapshot cadence for progress updates (default: {1, :seconds})
  - `:on_progress` - Callback receiving `%PropertyDamage.Progress{}` values: a
    `LoadUpdate` (metrics snapshot) each interval and a terminal `LoadResult`
    (final report). See `PropertyDamage.Progress` (DR-022).
  - `:assertion_mode` - How to handle assertions (default: `:disabled`):
    - `:disabled` - Skip all assertions (maximum throughput)
    - `:record` - Run assertions and record failures in metrics
    - `:log` - Run assertions and log failures as warnings

  ## Returns

  - `{:ok, report}` - Test completed successfully
  - `{:error, reason}` - Test failed to start

  ## Examples

      # Basic load test
      {:ok, report} = PropertyDamage.LoadTest.run(
        model: ToyBankTest.Model,
        adapter: ToyBankTest.HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4444"},
        concurrent_users: 50,
        duration: {2, :minutes}
      )

      # With ramping and callbacks
      {:ok, report} = PropertyDamage.LoadTest.run(
        model: TravelBookingTest.Model,
        adapter: TravelBookingTest.HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4445"},
        concurrent_users: 100,
        duration: {5, :minutes},
        ramp_up: {:linear, {60, :seconds}},
        on_progress: fn
          %PropertyDamage.Progress{data: %PropertyDamage.Progress.LoadUpdate{snapshot: m}} ->
            IO.puts("RPS: \#{m.requests_per_second}, P95: \#{m.latency_p95}ms")

          _ ->
            :ok
        end
      )
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts) do
    with {:ok, runner} <- Runner.start_link(opts) do
      Runner.await(runner)
    end
  end

  @doc """
  Run a load test asynchronously.

  Returns a runner pid that can be used to monitor progress and
  stop the test early.

  ## Returns

  - `{:ok, runner_pid}` - Runner started successfully
  - `{:error, reason}` - Failed to start

  ## Examples

      {:ok, runner} = PropertyDamage.LoadTest.start(opts)

      # Check status
      status = PropertyDamage.LoadTest.status(runner)

      # Get current metrics
      metrics = PropertyDamage.LoadTest.get_metrics(runner)

      # Wait for completion
      {:ok, report} = PropertyDamage.LoadTest.await(runner)

      # Or stop early
      {:ok, report} = PropertyDamage.LoadTest.stop(runner)
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    Runner.start_link(opts)
  end

  @doc """
  Wait for a running load test to complete.
  """
  @spec await(pid(), timeout()) :: {:ok, report()} | {:error, term()}
  def await(runner, timeout \\ :infinity) do
    Runner.await(runner, timeout)
  end

  @doc """
  Stop a running load test and get the report.
  """
  @spec stop(pid()) :: {:ok, report()}
  def stop(runner) do
    Runner.stop(runner)
  end

  @doc """
  Get current metrics from a running load test.
  """
  @spec get_metrics(pid()) :: map()
  def get_metrics(runner) do
    Runner.get_metrics(runner)
  end

  @doc """
  Get status of a running load test.
  """
  @spec status(pid()) :: map()
  def status(runner) do
    Runner.status(runner)
  end

  @doc """
  Format a report for display.

  ## Formats

  - `:terminal` - Colored terminal output with ASCII charts
  - `:markdown` - Markdown formatted report
  - `:json` - JSON format

  ## Examples

      {:ok, report} = PropertyDamage.LoadTest.run(opts)
      IO.puts(PropertyDamage.LoadTest.format(report, :terminal))
  """
  @spec format(report(), :terminal | :markdown | :json) :: String.t()
  def format(report, format \\ :terminal) do
    Report.format(report, format)
  end

  @doc """
  Generate a quick summary of a report.

  Returns a brief one-line summary suitable for logging.
  """
  @spec summary(report()) :: String.t()
  def summary(report) do
    Report.summary(report)
  end

  @doc """
  Save a report to a file.

  ## Examples

      {:ok, report} = PropertyDamage.LoadTest.run(opts)
      :ok = PropertyDamage.LoadTest.save(report, "load_test.md", :markdown)
  """
  @spec save(report(), Path.t(), :terminal | :markdown | :json) :: :ok | {:error, term()}
  def save(report, path, format \\ :markdown) do
    Report.save(report, path, format)
  end
end
