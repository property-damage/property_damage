defmodule PropertyDamage.ExUnitTest do
  use ExUnit.Case, async: true

  describe "format_failure/1" do
    test "formats basic failure report" do
      report = %{
        seed: 12_345,
        run_number: 0,
        original_commands: [%{type: :create}, %{type: :view}],
        shrunk_commands: [%{type: :create}],
        failed_at_index: 0,
        failure_reason: {:check_failed, :invariant, "Value too large"},
        shrink_iterations: 5,
        shrink_time_ms: 10
      }

      output = PropertyDamage.ExUnit.format_failure(report)

      assert output =~ "Seed: 12345"
      assert output =~ "Run: 1"
      assert output =~ "Original sequence (2 commands)"
      assert output =~ "Shrunk sequence (1 commands)"
      assert output =~ "Failed at command #0"
      assert output =~ "Check :invariant failed"
      assert output =~ "Value too large"
      assert output =~ "5 iterations"
      assert output =~ "seed: 12345"
    end

    test "formats adapter error" do
      report = %{
        seed: 1,
        run_number: 0,
        original_commands: [],
        shrunk_commands: [],
        failed_at_index: 0,
        failure_reason: {:adapter_error, :connection_failed},
        shrink_iterations: 0,
        shrink_time_ms: 0
      }

      output = PropertyDamage.ExUnit.format_failure(report)

      assert output =~ "Adapter error: :connection_failed"
    end

    test "formats ref resolution error" do
      report = %{
        seed: 1,
        run_number: 0,
        original_commands: [],
        shrunk_commands: [],
        failed_at_index: 0,
        failure_reason: {:ref_resolution_error, "Missing ref :foo"},
        shrink_iterations: 0,
        shrink_time_ms: 0
      }

      output = PropertyDamage.ExUnit.format_failure(report)

      assert output =~ "Ref resolution error: Missing ref :foo"
    end

    test "formats empty command sequences" do
      report = %{
        seed: 1,
        run_number: 0,
        original_commands: [],
        shrunk_commands: [],
        failed_at_index: 0,
        failure_reason: :unknown,
        shrink_iterations: 0,
        shrink_time_ms: 0
      }

      output = PropertyDamage.ExUnit.format_failure(report)

      assert output =~ "(empty)"
    end
  end

  describe "error handling" do
    test "raises when model is missing" do
      # KeyError is raised when required option is missing
      assert_raise KeyError, fn ->
        Keyword.fetch!([], :model)
      end
    end

    test "raises when adapter is missing" do
      assert_raise KeyError, fn ->
        Keyword.fetch!([model: Foo], :adapter)
      end
    end
  end
end

# Separate test module to test the macro
defmodule PropertyDamage.ExUnitTest.BasicPropertyTest do
  use ExUnit.Case
  use PropertyDamage.ExUnit

  property_damage("basic test passes",
    model: PropertyDamage.Test.ExecutorModel,
    adapter: PropertyDamage.Test.SimpleAdapter,
    max_runs: 3,
    max_commands: 5,
    validate: false
  )
end

defmodule PropertyDamage.ExUnitTest.WithOptionsPropertyTest do
  use ExUnit.Case
  use PropertyDamage.ExUnit

  property_damage("with options",
    model: PropertyDamage.Test.ExecutorModel,
    adapter: PropertyDamage.Test.SimpleAdapter,
    max_commands: 3,
    max_runs: 2,
    validate: false
  )
end

defmodule PropertyDamage.ExUnitTest.SeedPropertyTest do
  use ExUnit.Case
  use PropertyDamage.ExUnit

  property_damage("with fixed seed",
    model: PropertyDamage.Test.ExecutorModel,
    adapter: PropertyDamage.Test.SimpleAdapter,
    seed: 42,
    max_runs: 2,
    max_commands: 3,
    validate: false
  )
end
