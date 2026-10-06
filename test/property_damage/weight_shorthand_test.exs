defmodule PropertyDamage.WeightShorthandTest do
  # A command entry written `{Module, 3}` is no longer a weight: every place
  # that takes command entries rejects it with an error naming `weight:` and
  # the module, before any target is set up.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.Test.Expansion
  alias PropertyDamage.Test.Expansion.{Credit, Pay, Recorder}

  defp model!(name, opts), do: Expansion.define_model!(Module.concat(ExpansionA, name), opts)

  # Each model is defined once: the three entry points share it.
  setup_all do
    expansions = [{Pay, fn _pay, _state -> [[{Credit, 3}]] end}]

    %{
      root: model!(ShorthandRoot, commands: [{Pay, 3}]),
      in_setup: model!(ShorthandSetup, setup: [{Credit, 3}]),
      leaf: model!(ShorthandLeaf, expansions: expansions)
    }
  end

  defp assert_names_weight(message, module) do
    assert message =~ "weight:"
    assert message =~ inspect(module)
  end

  defp run_error(model) do
    recorder = start_recorder()

    message =
      Expansion.error_message(fn ->
        Expansion.run(model, [Expansion.target("a", recorder)], validate: true)
      end)

    assert Expansion.setups(recorder) == 0
    message
  end

  defp pd_validate(model, extra \\ []) do
    args = [inspect(model), "--targets", "[#{inspect(Recorder)}]"] ++ extra
    output = capture_io(fn -> send(self(), {:status, Validate.exec(args)}) end)
    assert_received {:status, status}
    {status, output}
  end

  describe "{Module, 3} in commands/0" do
    setup %{root: model}, do: %{model: model}

    test "fails PropertyDamage.run/1 before any setup", %{model: model} do
      model |> run_error() |> assert_names_weight(Pay)
    end

    test "fails Validation.validate!/3", %{model: model} do
      message =
        Expansion.error_message(fn -> PropertyDamage.Validation.validate!(model, Recorder) end)

      assert_names_weight(message, Pay)
    end

    test "fails mix pd.validate", %{model: model} do
      {status, output} = pd_validate(model)
      assert status == :error
      assert_names_weight(output, Pay)
    end
  end

  describe "{Module, 3} in setup_each/0" do
    setup %{in_setup: model}, do: %{model: model}

    test "fails PropertyDamage.run/1 before any setup", %{model: model} do
      model |> run_error() |> assert_names_weight(Credit)
    end

    test "fails Validation.validate!/3", %{model: model} do
      message =
        Expansion.error_message(fn -> PropertyDamage.Validation.validate!(model, Recorder) end)

      assert_names_weight(message, Credit)
    end

    test "fails mix pd.validate", %{model: model} do
      {status, output} = pd_validate(model)
      assert status == :error
      assert_names_weight(output, Credit)
    end
  end

  describe "{Module, 3} in an expansion sequence" do
    setup %{leaf: model}, do: %{model: model}

    test "fails PropertyDamage.run/1 before any setup", %{model: model} do
      model |> run_error() |> assert_names_weight(Credit)
    end

    test "fails mix pd.validate --seeds", %{model: model} do
      {status, output} = pd_validate(model, ["--seeds", "3", "--seed", "1"])
      assert status == :error
      assert_names_weight(output, Credit)
    end
  end

  describe "PropertyDamage.Model.normalize_commands/1" do
    test "raises the same error for {Module, 3}" do
      message =
        Expansion.error_message(fn -> PropertyDamage.Model.normalize_commands([{Pay, 3}]) end)

      assert_names_weight(message, Pay)

      exception =
        try do
          PropertyDamage.Model.normalize_commands([{Pay, 3}])
        rescue
          exception -> exception
        end

      refute is_struct(exception, CaseClauseError)
      refute is_struct(exception, FunctionClauseError)
    end
  end
end
