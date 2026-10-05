defmodule PropertyDamage.VariantFailureTest do
  # How a variant reports what ends it, and its two adapter-error modes.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Failure, Variant}

  alias PropertyDamage.Test.Lockstep.{
    GuardedStepModel,
    StartupModel,
    Step,
    StepAdapter,
    StepModel,
    Stepped
  }

  defp target(config) do
    [target] = targets!([{StepAdapter, name: "v", config: Map.merge(%{name: "v"}, config)}])
    target
  end

  defp start(target, model, commands, extra \\ []) do
    {:ok, pid} = Variant.start_link(variant_opts(target, model, commands, extra))
    pid
  end

  test "a check failure ends the variant and is reported again by later calls" do
    v = start(target(%{}), GuardedStepModel, [%Step{value: 1}, %Step{value: 13}, %Step{value: 3}])
    :ok = Variant.setup(v)

    assert {:ok, [{0, {:ok, [%Stepped{value: 1}]}}]} = Variant.advance_to(v, 0)

    assert {:failed, %{kind: :check_failed, root: 1, reason: reason} = failure} =
             Variant.advance_to(v, 2)

    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} = reason
    assert Variant.advance_to(v, 2) == {:failed, failure}

    result = Variant.finish(v)
    refute result.success
    assert result.failed_at_index == 1
    :ok = Variant.stop(v)
  end

  test "a failing :startup check is reported by the first advance_to with no root" do
    v = start(target(%{fail_startup: true, test_pid: self()}), StartupModel, [%Step{value: 1}])
    :ok = Variant.setup(v)

    assert {:failed, %{kind: :check_failed, root: nil}} = Variant.advance_to(v, 0)
    refute_received {:executed, _, _, _}
    :ok = Variant.stop(v)
  end

  test "an adapter error halts by default and is an observation under :continue" do
    commands = [%Step{value: 1, fail: true}, %Step{value: 2}]

    halting = start(target(%{}), StepModel, commands)
    :ok = Variant.setup(halting)

    assert {:failed, %{kind: :execution_failed, root: 0, reason: %Failure{}}} =
             Variant.advance_to(halting, 1)

    :ok = Variant.stop(halting)

    continuing = start(target(%{}), StepModel, commands, on_adapter_error: :continue)
    :ok = Variant.setup(continuing)

    assert {:ok, [{0, {:error, :refused}}, {1, {:ok, [%Stepped{value: 2}]}}]} =
             Variant.advance_to(continuing, 1)

    :ok = Variant.stop(continuing)
  end

  test "an adapter raise is an execution failure carrying the exception" do
    v = start(target(%{behavior: :raise}), StepModel, [%Step{value: 1}])
    :ok = Variant.setup(v)

    assert {:failed, %{kind: :execution_failed, root: 0, reason: %RuntimeError{}}} =
             Variant.advance_to(v, 0)

    :ok = Variant.stop(v)
  end

  test "a failing or raising setup is returned as an error and skips the adapter teardown" do
    for {result, expected} <- [error: {:error, :no_backend}, raise: :raised] do
      v = start(target(%{setup_result: result, test_pid: self()}), StepModel, [%Step{value: 1}])

      case expected do
        :raised -> assert {:error, {:raised, %RuntimeError{}}} = Variant.setup(v)
        expected -> assert Variant.setup(v) == expected
      end

      :ok = Variant.stop(v)
      refute_received {:teardown, _, _}
    end
  end
end
