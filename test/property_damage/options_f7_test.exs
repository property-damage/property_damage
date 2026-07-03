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

  # ---- Flakiness ------------------------------------------------------------

  describe "Options flakiness schemas" do
    test "check/4 defaults and unknown-key rejection" do
      assert Options.validate_flakiness_check!([])[:runs] == 5

      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:bogus\]/, fn ->
        Options.validate_flakiness_check!(bogus: 1)
      end
    end

    test "check_batch/4 rejects a type violation" do
      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_flakiness_check_batch!(runs_per_seed: 0)
      end
    end

    test "discover_flaky/3 defaults" do
      opts = Options.validate_flakiness_discover_flaky!([])
      assert opts[:num_seeds] == 10
      assert opts[:runs_per_seed] == 3
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
