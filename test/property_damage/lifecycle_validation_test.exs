defmodule PropertyDamage.LifecycleValidationTest do
  # The model's fixtures are setup and teardown commands. A model that still
  # defines a removed lifecycle hook fails before any target is set up, and
  # every setup and teardown entry is validated like a `commands/0` entry.
  # async: false because the `mix pd.validate` cases capture stdout.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.Test.SetupCommands
  alias PropertyDamage.Test.SetupCommands.{CreateUser, FixtureAdapter, Login}
  alias PropertyDamage.Validation

  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  # A model that defines `hook` on top of a valid model.
  defp model_with_hook!(name, hook) do
    support = SetupCommands
    module = Module.concat(__MODULE__, name)

    body =
      case hook do
        {fun, 0} -> quote(do: def(unquote(fun)(), do: :ok))
        {fun, 1} -> quote(do: def(unquote(fun)(_config), do: :ok))
      end

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          @moduledoc false
          @behaviour PropertyDamage.Model
          def commands, do: unquote(support).act_roots()
          def command_sequence_projection, do: unquote(SetupCommands.World)
          def check_projections, do: [unquote(SetupCommands.Fixture)]
          unquote(body)
        end
      end
    )

    module
  end

  defp run(model, recorder) do
    PropertyDamage.run(
      model: model,
      targets: [SetupCommands.target("a", recorder)],
      max_runs: 1,
      max_commands: 2,
      seed: 1,
      validate: false
    )
  end

  describe "a removed lifecycle hook" do
    for hook <- [
          setup_each: 1,
          setup_once: 0,
          setup_once: 1,
          teardown_each: 1,
          teardown_once: 0,
          teardown_once: 1
        ] do
      test "#{elem(hook, 0)}/#{elem(hook, 1)} fails run/1 before any adapter setup" do
        recorder = start_recorder()
        {fun, arity} = unquote(hook)
        model = model_with_hook!(Module.concat(Hook, "#{fun}#{arity}"), {fun, arity})

        error = assert_raise ArgumentError, fn -> run(model, recorder) end
        assert error.message =~ "setup_each/0"
        assert error.message =~ "teardown_each/0"
        assert error.message =~ "#{fun}/#{arity}"

        if fun in [:setup_once, :teardown_once] do
          assert error.message =~ "Adapter.setup/1"
        end

        assert recorded(recorder) == []
      end
    end

    test "fails Validation.validate!/3" do
      model = model_with_hook!(ValidateHook, {:setup_each, 1})

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, FixtureAdapter) end
      assert error.message =~ "setup_each/0"
    end
  end

  describe "setup and teardown entries" do
    test "an unknown module in setup_each/0 is rejected as in commands/0" do
      model = model!(Unknown, setup: [PropertyDamage.LifecycleValidationTest.NoSuchCommand])

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, FixtureAdapter) end
      assert error.message =~ "NoSuchCommand"
      assert error.message =~ "does not exist"
    end

    test "an override key the command does not define is rejected" do
      model = model!(BadKey, teardown: [{CreateUser, overrides: %{nmae: "x"}}])

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, FixtureAdapter) end
      assert error.message =~ "nmae"
    end

    test "a nemesis module in setup_each/0 is a validation error naming the callback" do
      model = model!(Nemesis, setup: [PropertyDamage.Nemesis.NetworkLatency])

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, FixtureAdapter) end
      assert error.message =~ "setup_each/0"
      assert error.message =~ "NetworkLatency"
    end

    test "when: and weight: warn that they are ignored in a sequence" do
      model =
        model!(Ignored,
          setup: [{CreateUser, weight: 3}],
          teardown: [{Login, when: fn _state -> true end}]
        )

      {:ok, warnings} = Validation.validate!(model, FixtureAdapter)

      assert "setup_each/0: #{inspect(CreateUser)} sets weight: ignored in a sequence" in warnings
      assert "teardown_each/0: #{inspect(Login)} sets when: ignored in a sequence" in warnings
    end
  end

  describe "mix pd.validate" do
    test "warns on when: and weight: in a setup or teardown entry" do
      model =
        model!(TaskIgnored,
          setup: [{CreateUser, weight: 2}],
          teardown: [{Login, when: fn _state -> true end}]
        )

      {status, output} =
        with_output(fn -> Validate.exec([inspect(model), inspect(FixtureAdapter)]) end)

      assert status == :ok
      assert output =~ "setup_each/0"
      assert output =~ "weight: ignored in a sequence"
      assert output =~ "when: ignored in a sequence"
    end

    test "errors on an arity-1 hook" do
      model = model_with_hook!(TaskHook, {:teardown_each, 1})

      {status, output} =
        with_output(fn -> Validate.exec([inspect(model), inspect(FixtureAdapter)]) end)

      assert status == :error
      assert output =~ "teardown_each/0"
    end

    test "errors on an arity-1 hook (model only)" do
      model = model_with_hook!(TaskHookModelOnly, {:setup_each, 1})

      {status, output} = with_output(fn -> Validate.exec([inspect(model)]) end)

      assert status == :error
      assert output =~ "setup_each/0"
    end

    test "passes a clean model with setup and teardown commands" do
      model =
        model!(TaskClean,
          setup: SetupCommands.standard_setup(),
          teardown: [{SetupCommands.Cleanup, overrides: %{thing_id: "x"}}]
        )

      {status, output} =
        with_output(fn -> Validate.exec([inspect(model), inspect(FixtureAdapter)]) end)

      assert status == :ok
      assert output =~ "VALIDATION PASSED"
      refute output =~ "ignored in a sequence"
    end
  end

  defp with_output(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:status, fun.()}) end)
    assert_received {:status, status}
    {status, output}
  end
end
