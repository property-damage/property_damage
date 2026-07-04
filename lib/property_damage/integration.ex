defmodule PropertyDamage.Integration do
  @moduledoc """
  Integration testing utilities for running PropertyDamage against live services.

  This module provides helpers for running property-based tests against real
  systems, with support for:

  - Health checks before testing
  - Database reset between runs
  - Report generation (terminal, markdown, JUnit XML)
  - Bug hunting mode (run until N unique bugs found)
  - Chaos testing with Toxiproxy

  ## Usage

      # Basic integration test
      {:ok, result} = PropertyDamage.Integration.run(
        model: MyModel,
        adapter: MyAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        max_runs: 100
      )

      # Bug hunting mode
      {:ok, bugs} = PropertyDamage.Integration.hunt_bugs(
        model: MyModel,
        adapter: MyAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        stop_after: 10  # Stop after 10 unique bugs
      )

  ## Health Checks

  Before running tests, the integration runner can verify the service is healthy:

      PropertyDamage.Integration.run(
        # ...
        health_check: %{
          url: "http://localhost:4000/api/health",
          timeout_ms: 5000,
          retries: 10
        }
      )

  ## Reports

  Generate reports in various formats:

      PropertyDamage.Integration.run(
        # ...
        report: %{
          format: :junit,
          path: "reports/integration.xml"
        }
      )

  Supported formats: `:terminal`, `:markdown`, `:junit`, `:json`
  """

  alias PropertyDamage.FailureIntelligence

  # Suppress warnings for optional Req dependency and :ssl (guarded at runtime)
  @compile {:no_warn_undefined, [Req, :ssl]}

  @default_health_check %{
    timeout_ms: 30_000,
    retries: 30,
    interval_ms: 1000
  }

  @doc """
  Run integration tests against a live service.

  ## Options

  - `:model` - The model module (required)
  - `:adapter` - The adapter module (required)
  - `:adapter_config` - Configuration for the adapter (required)
  - `:max_runs` - Number of test runs (default: 100)
  - `:max_commands` - Max commands per run (default: 50)
  - `:health_check` - Health check configuration (optional)
  - `:reset_fn` - Function to reset state between runs (optional)
  - `:report` - Report configuration (optional)
  - `:verbose` - Print progress (default: true)
  - `:stop_on_failure` - Stop on first failure (default: false)
  - `:save_failures` - Directory to save failures (optional)

  ## Returns

  - `{:ok, result}` - All tests passed
  - `{:error, result}` - Tests failed with failure details
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, map()}
  def run(opts) do
    opts = PropertyDamage.Options.validate_integration_run!(opts)
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.fetch!(opts, :adapter_config)
    max_runs = Keyword.get(opts, :max_runs, 100)
    max_commands = Keyword.get(opts, :max_commands, 50)
    verbose = Keyword.get(opts, :verbose, true)
    stop_on_failure = Keyword.get(opts, :stop_on_failure, false)
    save_failures = Keyword.get(opts, :save_failures)

    if verbose do
      print_header(model, adapter, adapter_config, max_runs)
    end

    # Health check
    case Keyword.get(opts, :health_check) do
      nil -> :ok
      health_opts -> perform_health_check(health_opts, verbose)
    end

    # Run tests
    start_time = System.monotonic_time(:millisecond)

    result =
      run_tests(
        model: model,
        adapter: adapter,
        adapter_config: adapter_config,
        max_runs: max_runs,
        max_commands: max_commands,
        verbose: verbose,
        stop_on_failure: stop_on_failure,
        save_failures: save_failures,
        reset_fn: Keyword.get(opts, :reset_fn)
      )

    elapsed = System.monotonic_time(:millisecond) - start_time

    result = Map.put(result, :duration_ms, elapsed)

    # Generate report if requested
    case Keyword.get(opts, :report) do
      nil -> :ok
      report_opts -> generate_report(result, report_opts)
    end

    if verbose do
      print_summary(result)
    end

    if result.success do
      {:ok, result}
    else
      {:error, result}
    end
  end

  @doc """
  Run tests until a specified number of unique bugs are found.

  ## Options

  - `:model` - The model module (required)
  - `:adapter` - The adapter module (required)
  - `:adapter_config` - Configuration for the adapter (required)
  - `:stop_after` - Stop after finding this many unique bugs (default: 10)
  - `:max_runs` - Maximum runs before giving up (default: :unlimited)
  - `:save_to` - Directory to save discovered bugs (optional)
  - `:verbose` - Print progress (default: true)

  ## Returns

  - `{:ok, bugs}` - List of unique bugs found
  """
  @spec hunt_bugs(keyword()) :: {:ok, [map()]}
  def hunt_bugs(opts) do
    opts = PropertyDamage.Options.validate_integration_hunt_bugs!(opts)
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.fetch!(opts, :adapter_config)
    stop_after = Keyword.get(opts, :stop_after, 10)
    max_runs = Keyword.get(opts, :max_runs, :unlimited)
    save_to = Keyword.get(opts, :save_to)
    verbose = Keyword.get(opts, :verbose, true)

    if verbose do
      IO.puts("\n")
      IO.puts(String.duplicate("═", 65))
      IO.puts(String.pad_leading("BUG HUNT MODE", 40))
      IO.puts(String.duplicate("═", 65))
      IO.puts("")
      IO.puts("Model:      #{inspect(model)}")
      IO.puts("Target:     #{stop_after} unique bugs")
      IO.puts("")
    end

    hunt_loop(
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      stop_after: stop_after,
      max_runs: max_runs,
      save_to: save_to,
      verbose: verbose,
      bugs: [],
      run_count: 0,
      start_time: System.monotonic_time(:millisecond)
    )
  end

  @doc """
  Perform a health check against a service.

  ## Options

  - `:url` - Health check URL (required)
  - `:timeout_ms` - Total timeout (default: 30000)
  - `:retries` - Number of retries (default: 30)
  - `:interval_ms` - Interval between retries (default: 1000)

  ## Returns

  - `:ok` - Service is healthy
  - `{:error, reason}` - Health check failed
  """
  @spec health_check(keyword()) :: :ok | {:error, term()}
  def health_check(opts) do
    opts = PropertyDamage.Options.validate_integration_health_check!(opts)
    url = Keyword.fetch!(opts, :url)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_health_check.timeout_ms)
    retries = Keyword.get(opts, :retries, @default_health_check.retries)
    interval_ms = Keyword.get(opts, :interval_ms, @default_health_check.interval_ms)

    do_health_check(url, retries, interval_ms, timeout_ms)
  end

  @doc """
  Generate a test report from integration results.

  ## Formats

  - `:terminal` - Print to console
  - `:markdown` - Generate markdown file
  - `:junit` - Generate JUnit XML for CI
  - `:json` - Generate JSON report

  ## Options

  - `:format` - Report format (required)
  - `:path` - Output file path (required for file formats)
  """
  @spec generate_report(map(), keyword() | map()) :: :ok
  def generate_report(result, opts) when is_list(opts) do
    generate_report(result, Map.new(opts))
  end

  def generate_report(result, %{format: :terminal}) do
    print_terminal_report(result)
  end

  def generate_report(result, %{format: :markdown, path: path}) do
    content = format_markdown_report(result)
    File.write!(path, content)
    IO.puts("Report saved to: #{path}")
  end

  def generate_report(result, %{format: :junit, path: path}) do
    content = format_junit_report(result)
    File.write!(path, content)
    IO.puts("JUnit report saved to: #{path}")
  end

  def generate_report(result, %{format: :json, path: path}) do
    content = Jason.encode!(result, pretty: true)
    File.write!(path, content)
    IO.puts("JSON report saved to: #{path}")
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp print_header(model, adapter, adapter_config, max_runs) do
    IO.puts("\n")
    IO.puts(String.duplicate("═", 65))
    IO.puts(String.pad_leading("PROPERTYDAMAGE INTEGRATION TEST", 48))
    IO.puts(String.duplicate("═", 65))
    IO.puts("")
    IO.puts("Model:      #{inspect(model)}")
    IO.puts("Adapter:    #{inspect(adapter)}")

    if Map.has_key?(adapter_config, :base_url) do
      IO.puts("Target:     #{adapter_config.base_url}")
    end

    IO.puts("Runs:       #{max_runs}")
    IO.puts("")
  end

  defp perform_health_check(opts, verbose) do
    url = opts[:url] || opts["url"]

    if verbose do
      IO.write("Health check (#{url})... ")
    end

    case health_check(Keyword.new(opts)) do
      :ok ->
        if verbose, do: IO.puts("✓ OK")
        :ok

      {:error, reason} ->
        if verbose, do: IO.puts("✗ FAILED")
        raise "Health check failed: #{inspect(reason)}"
    end
  end

  defp do_health_check(_url, 0, _interval, _timeout) do
    {:error, :max_retries_exceeded}
  end

  defp do_health_check(url, retries, interval_ms, timeout_ms) do
    start = System.monotonic_time(:millisecond)

    case http_get(url) do
      {:ok, status} when status in 200..299 ->
        :ok

      {:ok, status} ->
        elapsed = System.monotonic_time(:millisecond) - start

        if elapsed >= timeout_ms do
          {:error, {:unhealthy_status, status}}
        else
          Process.sleep(interval_ms)
          do_health_check(url, retries - 1, interval_ms, timeout_ms - elapsed)
        end

      {:error, _reason} ->
        elapsed = System.monotonic_time(:millisecond) - start

        if elapsed >= timeout_ms do
          {:error, :timeout}
        else
          Process.sleep(interval_ms)
          do_health_check(url, retries - 1, interval_ms, timeout_ms - elapsed)
        end
    end
  end

  defp http_get(url) do
    # Try to use Req if available, otherwise fall back to httpc
    if Code.ensure_loaded?(Req) do
      case Req.get(url, receive_timeout: 5000) do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end
    else
      httpc_get(url)
    end
  end

  # Fallback when Req is not available. The :inets/:ssl applications may be
  # unusable in some environments (their `start/0` then raises, e.g.
  # `UndefinedFunctionError` when :ssl is not loadable); treat any such failure as
  # a health-check error rather than letting it crash the caller, preserving the
  # `health_check/1` contract of `:ok | {:error, term()}`.
  defp httpc_get(url) do
    with :ok <- ensure_started(:inets),
         :ok <- ensure_started(:ssl) do
      request_via_httpc(url)
    end
  end

  defp ensure_started(app) do
    case app.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:http_client_unavailable, app, reason}}
    end
  rescue
    e -> {:error, {:http_client_unavailable, app, e}}
  end

  defp request_via_httpc(url) do
    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, [timeout: 5000], []) do
      {:ok, {{_, status, _}, _, _}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:http_client_error, e}}
  end

  defp run_tests(opts) do
    model = opts[:model]
    adapter = opts[:adapter]
    adapter_config = opts[:adapter_config]
    max_runs = opts[:max_runs]
    max_commands = opts[:max_commands]
    verbose = opts[:verbose]
    stop_on_failure = opts[:stop_on_failure]
    save_failures = opts[:save_failures]
    reset_fn = opts[:reset_fn]

    results =
      1..max_runs
      |> Enum.reduce_while(%{passed: 0, failed: 0, failures: []}, fn run_num, acc ->
        # Reset if function provided
        if reset_fn, do: reset_fn.()

        # Run single test
        result =
          PropertyDamage.run(
            model: model,
            adapter: adapter,
            adapter_config: adapter_config,
            max_commands: max_commands,
            max_runs: 1
          )

        if verbose do
          print_run_progress(run_num, max_runs, result)
        end

        case result do
          {:ok, _stats} ->
            {:cont, %{acc | passed: acc.passed + 1}}

          {:error, failure} ->
            # Save failure if requested
            if save_failures do
              save_failure(failure, save_failures, run_num)
            end

            new_acc = %{
              acc
              | failed: acc.failed + 1,
                failures: [failure | acc.failures]
            }

            if stop_on_failure do
              {:halt, new_acc}
            else
              {:cont, new_acc}
            end
        end
      end)

    %{
      success: results.failed == 0,
      total_runs: results.passed + results.failed,
      passed: results.passed,
      failed: results.failed,
      failures: Enum.reverse(results.failures),
      model: model,
      adapter: adapter
    }
  end

  defp print_run_progress(run_num, max_runs, result) do
    detail =
      case result do
        {:ok, stats} ->
          "#{String.pad_leading("#{stats.total_commands}", 3)} commands ✓"

        {:error, failure} ->
          "failed at command #{PropertyDamage.FailureReport.failure_index(failure)} ✗ (seed #{failure.seed})"
      end

    IO.puts("Run #{String.pad_leading("#{run_num}", 3)}/#{max_runs}: #{detail}")
  end

  defp save_failure(failure, dir, run_num) do
    File.mkdir_p!(dir)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    filename = "failure_#{timestamp}_run#{run_num}.json"
    path = Path.join(dir, filename)

    content = Jason.encode!(sanitize_for_json(failure), pretty: true)
    File.write!(path, content)
  end

  defp sanitize_for_json(data) when is_map(data) do
    data
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {k, sanitize_for_json(v)} end)
  rescue
    _ -> Map.new(data, fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(data) when is_list(data) do
    Enum.map(data, &sanitize_for_json/1)
  end

  defp sanitize_for_json(data) when is_tuple(data) do
    data |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(data) when is_atom(data), do: Atom.to_string(data)
  defp sanitize_for_json(data) when is_reference(data), do: inspect(data)
  defp sanitize_for_json(data) when is_pid(data), do: inspect(data)
  defp sanitize_for_json(data) when is_function(data), do: inspect(data)
  defp sanitize_for_json(data), do: data

  defp print_summary(result) do
    IO.puts("")
    IO.puts(String.duplicate("─", 65))

    if result.success do
      IO.puts("✓ All #{result.total_runs} runs passed! (#{result.duration_ms}ms)")
    else
      IO.puts("✗ #{result.failed}/#{result.total_runs} runs failed (#{result.duration_ms}ms)")

      if result.failures != [] do
        IO.puts("")
        IO.puts("First failure:")
        failure = hd(result.failures)
        IO.puts("  Seed: #{failure.seed}")

        IO.puts(
          "  Invariant: #{inspect(PropertyDamage.FailureReport.check_name(failure) || failure.failure_reason)}"
        )
      end
    end

    IO.puts("")
  end

  defp hunt_loop(opts) do
    bugs = opts[:bugs]
    run_count = opts[:run_count]
    stop_after = opts[:stop_after]
    max_runs = opts[:max_runs]
    verbose = opts[:verbose]
    save_to = opts[:save_to]
    start_time = opts[:start_time]

    # Check termination conditions
    if length(bugs) >= stop_after do
      elapsed = System.monotonic_time(:millisecond) - start_time

      if verbose do
        IO.puts("")
        IO.puts(String.duplicate("─", 65))
        IO.puts("✓ Found #{length(bugs)} unique bugs in #{run_count} runs (#{elapsed}ms)")
      end

      {:ok, bugs}
    else
      if max_runs != :unlimited and run_count >= max_runs do
        elapsed = System.monotonic_time(:millisecond) - start_time

        if verbose do
          IO.puts("")
          IO.puts(String.duplicate("─", 65))
          IO.puts("Reached max runs. Found #{length(bugs)}/#{stop_after} bugs (#{elapsed}ms)")
        end

        {:ok, bugs}
      else
        # Run one test
        result =
          PropertyDamage.run(
            model: opts[:model],
            adapter: opts[:adapter],
            adapter_config: opts[:adapter_config],
            max_commands: 50,
            max_runs: 1
          )

        new_run_count = run_count + 1

        new_bugs =
          case result do
            {:ok, _stats} ->
              bugs

            {:error, failure} ->
              # Check if this is a new unique bug
              is_new =
                not Enum.any?(bugs, fn bug ->
                  FailureIntelligence.similar?(bug.failure, failure)
                end)

              if is_new do
                fingerprint = FailureIntelligence.fingerprint(failure)

                bug = %{
                  fingerprint: fingerprint,
                  failure: failure,
                  occurrences: 1,
                  first_seen_run: new_run_count
                }

                if save_to do
                  save_failure(failure, save_to, new_run_count)
                end

                if verbose do
                  IO.puts(
                    "  [#{length(bugs) + 1}/#{stop_after}] New bug: #{inspect(fingerprint.check_name)}"
                  )
                end

                [bug | bugs]
              else
                # Increment occurrence count for existing bug
                Enum.map(bugs, fn bug ->
                  if FailureIntelligence.similar?(bug.failure, failure) do
                    %{bug | occurrences: bug.occurrences + 1}
                  else
                    bug
                  end
                end)
              end
          end

        # Print progress periodically
        if verbose and rem(new_run_count, 10) == 0 do
          elapsed = System.monotonic_time(:millisecond) - start_time

          IO.puts(
            "Runs: #{new_run_count} | Bugs: #{length(new_bugs)}/#{stop_after} | #{elapsed}ms"
          )
        end

        hunt_loop(Keyword.merge(opts, bugs: new_bugs, run_count: new_run_count))
      end
    end
  end

  defp print_terminal_report(result) do
    IO.puts("")
    IO.puts(String.duplicate("═", 65))
    IO.puts(String.pad_leading("INTEGRATION TEST REPORT", 44))
    IO.puts(String.duplicate("═", 65))
    IO.puts("")
    IO.puts("Model:      #{inspect(result.model)}")
    IO.puts("Adapter:    #{inspect(result.adapter)}")
    IO.puts("Duration:   #{result.duration_ms}ms")
    IO.puts("")
    IO.puts("Results:")
    IO.puts("  Total runs: #{result.total_runs}")
    IO.puts("  Passed:     #{result.passed}")
    IO.puts("  Failed:     #{result.failed}")
    IO.puts("  Pass rate:  #{Float.round(result.passed / result.total_runs * 100, 1)}%")

    if result.failed > 0 do
      IO.puts("")
      IO.puts("Failures:")

      result.failures
      |> Enum.take(5)
      |> Enum.with_index(1)
      |> Enum.each(fn {failure, idx} ->
        IO.puts(
          "  #{idx}. Seed: #{failure.seed}, Check: #{inspect(PropertyDamage.FailureReport.check_name(failure))}"
        )
      end)

      if length(result.failures) > 5 do
        IO.puts("  ... and #{length(result.failures) - 5} more")
      end
    end

    IO.puts("")
  end

  defp format_markdown_report(result) do
    """
    # PropertyDamage Integration Test Report

    ## Summary

    | Metric | Value |
    |--------|-------|
    | Model | `#{inspect(result.model)}` |
    | Adapter | `#{inspect(result.adapter)}` |
    | Duration | #{result.duration_ms}ms |
    | Total Runs | #{result.total_runs} |
    | Passed | #{result.passed} |
    | Failed | #{result.failed} |
    | Pass Rate | #{Float.round(result.passed / result.total_runs * 100, 1)}% |

    #{format_failures_markdown(result.failures)}

    ---
    Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """
  end

  defp format_failures_markdown([]), do: ""

  defp format_failures_markdown(failures) do
    failure_entries =
      failures
      |> Enum.take(10)
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {failure, idx} ->
        """
        ### Failure #{idx}

        - **Seed**: `#{failure.seed}`
        - **Check**: `#{inspect(PropertyDamage.FailureReport.check_name(failure))}`
        - **Error**: #{PropertyDamage.FailureReport.failure_message(failure) || "N/A"}
        """
      end)

    """
    ## Failures

    #{failure_entries}
    """
  end

  defp format_junit_report(result) do
    failures_xml =
      result.failures
      |> Enum.map_join("", fn failure ->
        """
            <testcase name="seed_#{failure.seed}" classname="#{inspect(result.model)}" time="0">
              <failure message="#{escape_xml(inspect(PropertyDamage.FailureReport.check_name(failure)))}">
                #{escape_xml(PropertyDamage.FailureReport.failure_message(failure) || "Check failed")}
              </failure>
            </testcase>
        """
      end)

    passed_xml =
      1..result.passed
      |> Enum.map_join("", fn n ->
        """
            <testcase name="run_#{n}" classname="#{inspect(result.model)}" time="0"/>
        """
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuite name="PropertyDamage Integration"
               tests="#{result.total_runs}"
               failures="#{result.failed}"
               errors="0"
               time="#{result.duration_ms / 1000}">
    #{passed_xml}#{failures_xml}
    </testsuite>
    """
  end

  defp escape_xml(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(other), do: escape_xml(inspect(other))
end
