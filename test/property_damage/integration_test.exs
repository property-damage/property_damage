defmodule PropertyDamage.IntegrationTest do
  @moduledoc """
  Tests for `PropertyDamage.Integration`, the module behind `mix pd.integration`.

  The mix task wrapper (`Mix.Tasks.Pd.Integration`) calls `System.halt/1` on
  every code path, so it cannot be exercised in-process. These tests drive the
  underlying `PropertyDamage.Integration` module directly, using the in-process
  test-support SUTs from `test/support/executor_test_support.ex` so that no live
  service is required.

  Reliable in-process combinations (verified empirically across many seeds):

    * Passing: `ExecutorModel` + `SimpleAdapter`, small budget (3 runs x 4 cmds).
    * Failing: `FailingModel` + `SimpleAdapter`, larger budget (5 runs x 60 cmds)
      so the cumulative-quantity assertion (`every: 1`, limit 100) is reliably
      tripped within the run.

  async: false because several tests print to stdout / write files.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PropertyDamage.Integration
  alias PropertyDamage.Test.{ExecutorModel, FailingModel, SimpleAdapter}

  # Budgets chosen so the SUT outcome is deterministic regardless of seed.
  @pass_runs 3
  @pass_commands 4
  @fail_runs 5
  @fail_commands 60

  defp passing_opts(extra \\ []) do
    Keyword.merge(
      [
        model: ExecutorModel,
        adapter: SimpleAdapter,
        adapter_config: %{},
        max_runs: @pass_runs,
        max_commands: @pass_commands,
        verbose: false
      ],
      extra
    )
  end

  defp failing_opts(extra \\ []) do
    Keyword.merge(
      [
        model: FailingModel,
        adapter: SimpleAdapter,
        adapter_config: %{},
        max_runs: @fail_runs,
        max_commands: @fail_commands,
        verbose: false
      ],
      extra
    )
  end

  describe "run/1 - passing SUT" do
    test "returns {:ok, result} with the expected summary shape" do
      assert {:ok, result} = Integration.run(passing_opts())

      assert result.success == true
      assert result.failed == 0
      assert result.passed == @pass_runs
      assert result.total_runs == @pass_runs
      assert result.failures == []
      assert result.model == ExecutorModel
      assert result.adapter == SimpleAdapter
      assert is_integer(result.duration_ms)
    end

    test "verbose: true prints a header and summary but still returns {:ok, _}" do
      output =
        capture_io(fn ->
          assert {:ok, _result} = Integration.run(passing_opts(verbose: true))
        end)

      assert output =~ "PROPERTYDAMAGE INTEGRATION TEST"
      assert output =~ "runs passed"
    end
  end

  describe "run/1 - failing SUT" do
    test "returns {:error, result} with failure details" do
      assert {:error, result} = Integration.run(failing_opts())

      assert result.success == false
      assert result.failed >= 1
      assert result.total_runs == @fail_runs
      assert result.passed + result.failed == result.total_runs

      # failures are %FailureReport{} structs.
      failure = hd(result.failures)
      assert %PropertyDamage.FailureReport{} = failure
      assert PropertyDamage.FailureReport.check_name(failure) == :quantity_limit
      assert is_integer(failure.seed)
    end

    test "stop_on_failure: true halts after the first failing run" do
      assert {:error, result} = Integration.run(failing_opts(stop_on_failure: true))

      # With stop_on_failure, the reduce halts on the first failure, so we never
      # accumulate more than one failed run.
      assert result.failed == 1
      assert result.total_runs == result.passed + 1
    end
  end

  describe "run/1 - report option" do
    test "report: %{format: :terminal} prints the report inline" do
      output =
        capture_io(fn ->
          assert {:ok, _result} =
                   Integration.run(passing_opts(report: %{format: :terminal}))
        end)

      assert output =~ "INTEGRATION TEST REPORT"
    end
  end

  describe "run/1 - health_check option" do
    test "raises when the health check fails (retries: 0 base case)" do
      # retries: 0 short-circuits to {:error, :max_retries_exceeded} without any
      # HTTP call, and perform_health_check/2 raises on an error result.
      assert_raise RuntimeError, ~r/Health check failed/, fn ->
        Integration.run(passing_opts(health_check: %{url: "http://unused.invalid", retries: 0}))
      end
    end
  end

  describe "hunt_bugs/1" do
    test "returns {:ok, bugs} with bug maps shaped as expected" do
      assert {:ok, bugs} =
               Integration.hunt_bugs(
                 model: FailingModel,
                 adapter: SimpleAdapter,
                 adapter_config: %{},
                 stop_after: 1,
                 max_runs: 30,
                 verbose: false
               )

      assert is_list(bugs)
      assert bugs != []

      bug = hd(bugs)
      assert Map.has_key?(bug, :fingerprint)
      assert Map.has_key?(bug, :failure)
      assert bug.occurrences >= 1
      assert is_integer(bug.first_seen_run)

      assert %PropertyDamage.FailureIntelligence.Fingerprint{} = bug.fingerprint
      assert %PropertyDamage.FailureReport{} = bug.failure
    end

    test "stops at max_runs when target is unreachable (passing SUT, no bugs)" do
      assert {:ok, bugs} =
               Integration.hunt_bugs(
                 model: ExecutorModel,
                 adapter: SimpleAdapter,
                 adapter_config: %{},
                 stop_after: 5,
                 max_runs: 3,
                 verbose: false
               )

      # A passing SUT never produces a bug, so the loop exhausts max_runs and
      # returns the (empty) accumulated bug list.
      assert bugs == []
    end

    # Regression: a discovered failure carries maps keyed by
    # `%PropertyDamage.Sequence.Position{}` structs. `save_to` JSON-encodes the
    # failure, and `Jason.Encode.key/2` raised on the Position key (no
    # String.Chars impl). The fix stringifies non-string/atom map keys in
    # `sanitize_for_json/1`, so save_to must write valid JSON without raising.
    @tag :tmp_dir
    test "save_to writes a valid JSON file (Position-keyed maps do not crash encoding)",
         %{tmp_dir: dir} do
      assert {:ok, bugs} =
               Integration.hunt_bugs(
                 model: FailingModel,
                 adapter: SimpleAdapter,
                 adapter_config: %{},
                 stop_after: 1,
                 max_runs: 30,
                 save_to: dir,
                 verbose: false
               )

      assert bugs != []

      files = File.ls!(dir)
      assert files != []

      for file <- files do
        content = File.read!(Path.join(dir, file))
        assert {:ok, _decoded} = Jason.decode(content)
      end
    end
  end

  describe "health_check/1" do
    test "returns {:error, :max_retries_exceeded} when retries are exhausted" do
      # retries: 0 is the deterministic base case: it returns an error tuple
      # without performing any network I/O.
      assert {:error, :max_retries_exceeded} =
               Integration.health_check(url: "http://unused.invalid/health", retries: 0)
    end

    test "returns an error tuple (does not crash) when the HTTP client is unavailable" do
      # With retries: 1 the check performs a real HTTP attempt. When neither Req
      # nor the :inets/:ssl httpc stack is usable, the fallback must degrade to an
      # {:error, _} result, honouring the :ok | {:error, term()} contract, rather
      # than raising (e.g. UndefinedFunctionError from :ssl.start/0).
      assert {:error, _reason} =
               Integration.health_check(
                 url: "http://unused.invalid/health",
                 retries: 1,
                 interval_ms: 1,
                 timeout_ms: 50
               )
    end
  end

  describe "generate_report/2" do
    setup do
      {:ok, result} = Integration.run(passing_opts())
      %{result: result}
    end

    test "terminal format (keyword opts) returns :ok and prints stable substrings",
         %{result: result} do
      output =
        capture_io(fn ->
          send(self(), {:ret, Integration.generate_report(result, format: :terminal)})
        end)

      assert_received {:ret, :ok}
      assert output =~ "INTEGRATION TEST REPORT"
      assert output =~ "Total runs:"
      assert output =~ "Pass rate:"
    end

    test "terminal format (map opts) returns :ok", %{result: result} do
      capture_io(fn ->
        assert :ok = Integration.generate_report(result, %{format: :terminal})
      end)
    end

    test "markdown format writes a file with the expected content", %{result: result} do
      path = report_path("markdown") <> ".md"
      on_exit(fn -> File.rm(path) end)

      capture_io(fn ->
        Integration.generate_report(result, %{format: :markdown, path: path})
      end)

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "# PropertyDamage Integration Test Report"
      assert content =~ "Total Runs"
      assert content =~ "ExecutorModel"
    end

    test "json format writes parseable JSON", %{result: result} do
      path = report_path("json") <> ".json"
      on_exit(fn -> File.rm(path) end)

      capture_io(fn ->
        Integration.generate_report(result, %{format: :json, path: path})
      end)

      assert File.exists?(path)
      decoded = path |> File.read!() |> Jason.decode!()
      assert decoded["total_runs"] == @pass_runs
      assert decoded["success"] == true
    end

    test "junit format writes XML with a testsuite element", %{result: result} do
      path = report_path("junit") <> ".xml"
      on_exit(fn -> File.rm(path) end)

      capture_io(fn ->
        Integration.generate_report(result, %{format: :junit, path: path})
      end)

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ ~s(<testsuite name="PropertyDamage Integration")
      assert content =~ ~s(tests="#{@pass_runs}")
    end
  end

  # Derives a temp-file base path from a static prefix (no Date/random), so it is
  # stable per format and cleaned up via on_exit/1.
  defp report_path(suffix) do
    Path.join(System.tmp_dir!(), "pd_integration_test_#{suffix}")
  end
end
