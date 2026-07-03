defmodule PropertyDamage.OptionsF7Test do
  # Covers the F7 fail-fast option schemas: each new entry point validates its
  # options up front, rejecting unknown keys and type violations. Also locks the
  # Regression factory-time validation (the silent-artifact-loss fix) and the
  # newly-wired Analysis.generate_test orphan schema.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Analysis, FailureReport, Options, Regression, Sequence}

  defmodule TestCmd, do: defstruct(id: nil)

  # ---- Integration ----------------------------------------------------------

  describe "Options.validate_integration_run!/1" do
    test "applies defaults on the happy path" do
      opts = Options.validate_integration_run!(model: M, adapter: A, adapter_config: %{})
      assert opts[:max_runs] == 100
      assert opts[:max_commands] == 50
      assert opts[:verbose] == true
      assert opts[:stop_on_failure] == false
    end

    test "rejects an unknown option" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:bogus\]/, fn ->
        Options.validate_integration_run!(model: M, adapter: A, adapter_config: %{}, bogus: 1)
      end
    end

    test "rejects a type violation" do
      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_integration_run!(model: M, adapter: A, adapter_config: %{}, max_runs: -1)
      end
    end
  end

  describe "Options.validate_run!/1 :mock_services (WP-C5)" do
    test "defaults to an empty list" do
      opts = Options.validate_run!(model: M, adapter: A)
      assert opts[:mock_services] == []
    end

    test "normalizes bare modules to {module, %{}} tuples" do
      opts = Options.validate_run!(model: M, adapter: A, mock_services: [PayMock])
      assert opts[:mock_services] == [{PayMock, %{}}]
    end

    test "keeps {module, config} tuples and preserves config" do
      opts =
        Options.validate_run!(model: M, adapter: A, mock_services: [{PayMock, %{port: 4445}}])

      assert opts[:mock_services] == [{PayMock, %{port: 4445}}]
    end

    test "rejects a malformed entry" do
      assert_raise NimbleOptions.ValidationError, ~r/module or \{module, config_map\}/, fn ->
        Options.validate_run!(model: M, adapter: A, mock_services: ["not-a-module"])
      end
    end

    test "rejects a non-list value" do
      assert_raise NimbleOptions.ValidationError, ~r/list of mock services/, fn ->
        Options.validate_run!(model: M, adapter: A, mock_services: PayMock)
      end
    end
  end

  describe "Options.validate_integration_hunt_bugs!/1" do
    test "accepts :unlimited for max_runs and defaults stop_after" do
      opts = Options.validate_integration_hunt_bugs!(model: M, adapter: A, adapter_config: %{})
      assert opts[:stop_after] == 10
      assert opts[:max_runs] == :unlimited
    end

    test "rejects an unknown option (e.g. run/1's health_check leaking in)" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:health_check\]/, fn ->
        Options.validate_integration_hunt_bugs!(
          model: M,
          adapter: A,
          adapter_config: %{},
          health_check: %{}
        )
      end
    end
  end

  describe "Options.validate_integration_health_check!/1" do
    test "requires :url" do
      assert_raise NimbleOptions.ValidationError, ~r/required :url option not found/, fn ->
        Options.validate_integration_health_check!(retries: 0)
      end
    end

    test "rejects an unknown option" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:bogus\]/, fn ->
        Options.validate_integration_health_check!(url: "http://x", bogus: 1)
      end
    end
  end

  # ---- Audit ----------------------------------------------------------------

  describe "Options.validate_audit!/1" do
    test "accepts an integer seed count (default 100) or an explicit list" do
      assert Options.validate_audit!([])[:seeds] == 100
      assert Options.validate_audit!(seeds: [1, 2, 3])[:seeds] == [1, 2, 3]
    end

    test "rejects an unknown option" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:bogus\]/, fn ->
        Options.validate_audit!(bogus: 1)
      end
    end
  end

  # ---- RunComparison --------------------------------------------------------

  describe "Options run comparison schemas" do
    test "compare/2 rejects an unknown option" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:bogus\]/, fn ->
        Options.validate_run_comparison_compare!(bogus: 1)
      end
    end

    test "investigate/1 requires :capture and defaults :runs" do
      assert_raise NimbleOptions.ValidationError, ~r/required :capture option not found/, fn ->
        Options.validate_run_comparison_investigate!(runs: 3)
      end

      opts =
        Options.validate_run_comparison_investigate!(capture: [model: M, adapter: A, seed: 1])

      assert opts[:runs] == 5
    end

    test "scan/1 requires :seeds and :capture and defaults :runs" do
      assert_raise NimbleOptions.ValidationError, ~r/required :seeds option not found/, fn ->
        Options.validate_run_comparison_scan!(capture: [model: M, adapter: A])
      end

      assert_raise NimbleOptions.ValidationError, ~r/required :capture option not found/, fn ->
        Options.validate_run_comparison_scan!(seeds: [1, 2])
      end

      opts =
        Options.validate_run_comparison_scan!(seeds: [1, 2], capture: [model: M, adapter: A])

      assert opts[:runs] == 5
    end
  end

  # ---- Regression factory-time fail-fast (silent-artifact-loss fix) ---------

  describe "Regression factories validate at factory time" do
    test "generate_test/2 raises on a bad option immediately, not when the handler fires" do
      # RED against baseline: baseline returned a closure that only raised (and
      # was swallowed by compose/1) when a failure was eventually found.
      assert_raise NimbleOptions.ValidationError, fn ->
        Regression.generate_test("dir", bogus: 1)
      end

      assert is_function(Regression.generate_test("dir", module_name: "X"), 1)
    end

    test "generate_test/2 rejects :base_url (inapplicable to :exunit)" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:base_url\]/, fn ->
        Regression.generate_test("dir", base_url: "http://x")
      end
    end

    test "save_failure/2 raises on a bad option at factory time" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Regression.save_failure("dir", bogus: 1)
      end

      assert is_function(Regression.save_failure("dir", overwrite: true), 1)
    end

    test "add_to_library/2 raises on a bad option at factory time" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Regression.add_to_library("path", bogus: 1)
      end

      assert is_function(Regression.add_to_library("path", tags: [:x]), 1)
    end
  end

  # ---- regression: run-option :adapter parity (WP-C4 c) ---------------------

  describe "run/1 :regression option accepts :adapter" do
    test "the run schema validates regression: [adapter: ...] and preserves it" do
      # RED against baseline: the run-level :regression keys omitted :adapter, so
      # NimbleOptions rejected it as an unknown key and the generated regression
      # test silently fell back to report.adapter. Regression.handler/1 accepts
      # :adapter, so the run option must reach it.
      opts =
        Options.validate_run!(
          model: __MODULE__,
          adapter: __MODULE__,
          regression: [generate_tests: "dir", adapter: __MODULE__]
        )

      assert get_in(opts, [:regression, :adapter]) == __MODULE__
    end

    test "the value survives Regression.handler/1's own validation" do
      # The umbrella handler schema already accepts :adapter; prove the two
      # schemas agree so the threaded value is not dropped on the way down.
      handler = Regression.handler(generate_tests: "dir", adapter: __MODULE__)
      assert is_function(handler, 1)
    end
  end

  # ---- Orphan schema wired into Analysis.generate_test ----------------------

  describe "Analysis.generate_test/2 validates options" do
    setup do
      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: Sequence.linear([%TestCmd{id: "1"}]),
          shrunk_sequence: Sequence.linear([%TestCmd{id: "1"}]),
          failed_at_index: 0,
          failure_reason: {:check_failed, :SomeCheck, "boom"}
        )

      {:ok, report: report}
    end

    test "rejects an unknown option (RED against baseline: passed silently)", %{report: report} do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:bogus\]/, fn ->
        Analysis.generate_test(report, bogus: :x)
      end
    end

    test "still generates on the happy path", %{report: report} do
      assert is_binary(Analysis.generate_test(report, format: :exunit))
    end
  end
end
