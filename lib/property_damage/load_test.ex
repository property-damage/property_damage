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

  ## Quick Start

      # Run a 2-minute load test with 50 concurrent users
      {:ok, report} = PropertyDamage.LoadTest.run(
        model: MyApp.TestModel,
        adapter: MyApp.HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        concurrent_users: 50,
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
        concurrent_users: 100,
        duration: {5, :minutes},

        # Ramp strategy - gradually increase load
        ramp_up: {:linear, {30, :seconds}},
        ramp_down: {:linear, {10, :seconds}},

        # Session behavior
        commands_per_session: {10, 50},
        think_time: {100, 500},

        # Live metrics (called every second)
        on_metrics: fn metrics ->
          IO.puts("RPS: \#{metrics.requests_per_second}, p95: \#{metrics.latency_p95}ms")
        end,

        # Called when test completes
        on_complete: fn report ->
          PropertyDamage.LoadTest.Report.save(report, "load_test.md", :markdown)
        end
      )

  ## Ramp Strategies

  Control how load is applied over time:

  - `:immediate` - All users start at once
  - `{:linear, duration}` - Gradual linear ramp
  - `{:step, count, interval}` - Add users in steps
  - `{:exponential, duration}` - Exponential growth curve

  ## Metrics Collected

  - **Throughput**: Total requests, requests/second
  - **Latency**: p50, p95, p99, min, max, mean
  - **Errors**: Total count, error rate, by type
  - **Assertions**: Failures count, rate, by assertion name (when enabled)
  - **Per-Command**: Breakdown by command type
  - **History**: Time series for trend analysis

  ## Architecture

  ```
  PropertyDamage.LoadTest
  ├── Runner         # Orchestrates concurrent sessions
  ├── Session        # Single user session (sequence execution)
  ├── Metrics        # Collects latency, throughput, errors
  ├── RampStrategy   # Controls load ramping
  └── Report         # Generates load test reports
  ```
  """

  alias PropertyDamage.LoadTest.{Runner, Report}

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
  - `:metrics_interval` - Callback interval (default: {1, :seconds})
  - `:on_metrics` - Callback receiving metrics snapshot each interval
  - `:on_complete` - Callback receiving final report
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
        on_metrics: fn m ->
          IO.puts("RPS: \#{m.requests_per_second}, P95: \#{m.latency_p95}ms")
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
