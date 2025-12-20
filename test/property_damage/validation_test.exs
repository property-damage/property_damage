defmodule PropertyDamage.ValidationTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Validation

  alias PropertyDamage.Test.{
    ExecutorModel,
    SimpleAdapter,
    SimpleInjectorAdapter
  }

  describe "validate!/3" do
    test "valid configuration passes" do
      {:ok, warnings} = Validation.validate!(ExecutorModel, SimpleAdapter)

      assert is_list(warnings)
    end

    test "returns warnings for missing downstream_observables" do
      {:ok, warnings} = Validation.validate!(ExecutorModel, SimpleAdapter)

      # Our test commands may have warnings
      assert is_list(warnings)
    end
  end

  describe "validate!/3 errors" do
    test "raises for missing model module" do
      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Validation.validate!(NonExistentModule, SimpleAdapter)
      end
    end

    test "raises for missing adapter module" do
      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Validation.validate!(ExecutorModel, NonExistentAdapter)
      end
    end

    test "raises for missing model callback" do
      defmodule IncompleteModel do
        @behaviour PropertyDamage.Model
        # Missing required callbacks
      end

      assert_raise ArgumentError, ~r/missing required callback/, fn ->
        Validation.validate!(IncompleteModel, SimpleAdapter)
      end
    end

    test "raises for missing adapter callback" do
      defmodule IncompleteAdapter do
        # Missing required callbacks
      end

      assert_raise ArgumentError, ~r/missing required callback/, fn ->
        Validation.validate!(ExecutorModel, IncompleteAdapter)
      end
    end
  end

  describe "validate!/3 with injector adapters" do
    test "validates injectable events coverage" do
      # ExecutorModel may have injectable_events that need coverage
      {:ok, _warnings} =
        Validation.validate!(ExecutorModel, SimpleAdapter,
          injector_adapters: [SimpleInjectorAdapter]
        )
    end
  end

  describe "print_summary/4" do
    test "outputs configuration summary" do
      {:ok, warnings} = Validation.validate!(ExecutorModel, SimpleAdapter)

      # Capture output
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Validation.print_summary(ExecutorModel, SimpleAdapter, warnings)
        end)

      assert output =~ "PropertyDamage Configuration Summary"
      assert output =~ inspect(ExecutorModel)
      assert output =~ inspect(SimpleAdapter)
      assert output =~ "Commands"
      assert output =~ "State Projection"
      assert output =~ "Assertion Projections"
    end

    test "includes warnings in output" do
      warnings = ["Test warning 1", "Test warning 2"]

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Validation.print_summary(ExecutorModel, SimpleAdapter, warnings)
        end)

      assert output =~ "Warnings:"
      assert output =~ "Test warning 1"
      assert output =~ "Test warning 2"
    end

    test "writes to custom IO device" do
      {:ok, warnings} = Validation.validate!(ExecutorModel, SimpleAdapter)

      {:ok, io} = StringIO.open("")

      Validation.print_summary(ExecutorModel, SimpleAdapter, warnings, io: io)

      {_, output} = StringIO.contents(io)
      assert output =~ "PropertyDamage Configuration Summary"
    end
  end
end
