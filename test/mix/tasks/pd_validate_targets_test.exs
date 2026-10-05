defmodule Mix.Tasks.Pd.ValidateTargetsTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Validate

  @model "PropertyDamage.Test.ExecutorModel"
  @simple "PropertyDamage.Test.SimpleAdapter"
  @other "PropertyDamage.Test.TestAdapter"

  defp run_with_targets(targets_expr) do
    capture_io(fn -> Validate.exec([@model, "--targets", targets_expr]) end)
  end

  describe "isolation warning for --targets" do
    test "warns when two targets share an adapter and an identical config" do
      output =
        run_with_targets(
          "[{#{@simple}, config: %{tenant: 1}}, " <>
            "{#{@simple}, name: \"b\", config: %{tenant: 1}}]"
        )

      assert output =~ "identical `config:`"
      assert output =~ ~s|"SimpleAdapter" (index 0)|
      assert output =~ ~s|"b" (index 1)|
    end

    test "does not warn when the same adapter has different configs" do
      output =
        run_with_targets(
          "[{#{@simple}, config: %{tenant: 1}}, " <>
            "{#{@simple}, name: \"b\", config: %{tenant: 2}}]"
        )

      # The targets were read and validated: the run reached the verdict.
      assert output =~ "VALIDATION PASSED"
      refute output =~ "identical `config:`"
    end

    test "does not warn when identical configs are on different adapters" do
      output =
        run_with_targets(
          "[{#{@simple}, config: %{tenant: 1}}, {#{@other}, config: %{tenant: 1}}]"
        )

      # The targets were read and validated: the run reached the verdict.
      assert output =~ "VALIDATION PASSED"
      refute output =~ "identical `config:`"
    end
  end
end
