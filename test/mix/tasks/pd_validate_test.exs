defmodule Mix.Tasks.Pd.ValidateTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate

  # Success paths are exercised through `run/1` (which returns normally on
  # success). Failure paths are exercised through `exec/1`, the halt-free seam:
  # `run/1` only translates `exec/1`'s `:error` status into `System.halt/1` at the
  # boundary, so the decision logic is testable in-process without killing the
  # test runner.
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

  describe "exec/1 status (halt-free seam)" do
    test "returns :ok on the two-argument success path" do
      assert capture_status(fn -> Validate.exec([@model, @adapter]) end) == :ok
    end

    test "returns :ok on the model-only success path" do
      assert capture_status(fn -> Validate.exec([@model]) end) == :ok
    end

    test "returns :error and reports a missing adapter module" do
      {status, output} =
        with_output(fn -> Validate.exec([@model, "Nonexistent.Adapter"]) end)

      assert status == :error
      assert output =~ "Adapter module"
      assert output =~ "does not exist"
    end

    test "returns :error and reports a missing model module (model-only)" do
      {status, output} = with_output(fn -> Validate.exec(["Nonexistent.Model"]) end)

      assert status == :error
      assert output =~ "Model module"
      assert output =~ "does not exist"
    end

    test "returns :error in --strict mode when warnings are present" do
      {status, output} =
        with_output(fn -> Validate.exec([@model, @adapter, "--strict"]) end)

      assert status == :error
      assert output =~ "strict mode"
    end

    test "returns :error for the wrong number of arguments" do
      {status, output} = with_output(fn -> Validate.exec(["a", "b", "c"]) end)

      assert status == :error
      assert output =~ "Expected 1 or 2 arguments"
    end
  end

  # Run `fun` while swallowing its stdout, returning only its status.
  defp capture_status(fun) do
    {status, _output} = with_output(fun)
    status
  end

  # Run `fun`, returning {status, captured_stdout}.
  defp with_output(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:status, fun.()}) end)
    assert_received {:status, status}
    {status, output}
  end
end
