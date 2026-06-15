defmodule Mix.Tasks.Pd.ValidateTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate

  # We deliberately only exercise the SUCCESS paths of `run/1` that return
  # normally. Every failure path in this task calls `System.halt/1`, which
  # terminates the BEAM and would kill the test runner, so those paths are not
  # testable in-process (see the moduledoc note below and the report).
  #
  # The valid test-support modules used here:
  #   * PropertyDamage.Test.ExecutorModel  - valid model with commands,
  #     command_sequence_projection, and assertion_projections.
  #   * PropertyDamage.Test.SimpleAdapter  - valid adapter.
  #
  # validate!/2 on this pair returns {:ok, warnings} with two "produced but not
  # handled" warnings. In plain (non-strict) mode warnings do NOT halt, so the
  # task prints "VALIDATION PASSED" and returns. We never pass --strict, because
  # strict + warnings would call System.halt(1).

  @model "PropertyDamage.Test.ExecutorModel"
  @adapter "PropertyDamage.Test.SimpleAdapter"

  describe "two-argument success path (validate_and_report, plain mode)" do
    test "prints the validation header and VALIDATION PASSED" do
      output = capture_io(fn -> Validate.run([@model, @adapter]) end)

      assert output =~ "PropertyDamage Validation"
      assert output =~ "VALIDATION PASSED"
    end

    test "prints the model/adapter/command summary" do
      output = capture_io(fn -> Validate.run([@model, @adapter]) end)

      assert output =~ "Model:      PropertyDamage.Test.ExecutorModel"
      assert output =~ "Adapter:    PropertyDamage.Test.SimpleAdapter"
      assert output =~ "Commands:   2"
      assert output =~ "Extra:      1"
    end

    test "reports non-fatal warnings without failing" do
      output = capture_io(fn -> Validate.run([@model, @adapter]) end)

      assert output =~ "WARNINGS (2):"
      assert output =~ "produced but not handled"
      # Plain mode: warnings present but validation still passes.
      assert output =~ "VALIDATION PASSED"
      refute output =~ "VALIDATION FAILED"
    end

    test "--verbose adds the detailed configuration summary" do
      output = capture_io(fn -> Validate.run([@model, @adapter, "--verbose"]) end)

      assert output =~ "PropertyDamage Configuration Summary"
      assert output =~ "Commands (2):"
      assert output =~ "State Projection: PropertyDamage.Test.Projections.ModelState"
      assert output =~ "VALIDATION PASSED"
    end
  end

  describe "one-argument model-only success path (validate_model_only, plain mode)" do
    test "notes the missing adapter and prints MODEL VALIDATION PASSED" do
      output = capture_io(fn -> Validate.run([@model]) end)

      assert output =~ "No adapter specified. Validating model only."
      assert output =~ "MODEL VALIDATION PASSED"
    end

    test "--verbose adds the model summary" do
      output = capture_io(fn -> Validate.run([@model, "--verbose"]) end)

      assert output =~ "Model: PropertyDamage.Test.ExecutorModel"
      assert output =~ "Commands (2):"
      assert output =~ "State Projection: PropertyDamage.Test.Projections.ModelState"
      assert output =~ "MODEL VALIDATION PASSED"
    end
  end
end
