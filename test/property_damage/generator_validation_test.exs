defmodule PropertyDamage.GeneratorValidationTest do
  @moduledoc """
  Input validation for command weights and branching bounds: bad values that
  used to fail obscurely deep in generation (or spin) now fail fast and clearly.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Model, Options}

  defmodule Cmd do
    use PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
  end

  defmodule CmdWithWith do
    use PropertyDamage.Command, with: %{x: 1}
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
  end

  describe "command weight validation" do
    test "a zero weight is rejected with a clear error" do
      assert_raise ArgumentError, ~r/weight must be a positive integer/, fn ->
        Model.normalize_command_spec({Cmd, weight: 0})
      end
    end

    test "a negative weight is rejected" do
      assert_raise ArgumentError, ~r/weight must be a positive integer/, fn ->
        Model.normalize_command_spec({Cmd, weight: -3})
      end
    end

    test "a positive weight still normalizes" do
      assert {5, Cmd, %{weight: 5}} = Model.normalize_command_spec({Cmd, weight: 5})
    end
  end

  describe "command :when arity validation" do
    test "a zero-arity when: is rejected with a clear error" do
      assert_raise ArgumentError, ~r/`when:` for command.*1-arity/s, fn ->
        Model.normalize_command_spec({Cmd, when: fn -> true end})
      end
    end

    test "a two-arity when: is rejected" do
      assert_raise ArgumentError, ~r/`when:` for command.*1-arity/s, fn ->
        Model.normalize_command_spec({Cmd, when: fn _a, _b -> true end})
      end
    end

    test "a non-function when: is rejected" do
      assert_raise ArgumentError, ~r/`when:` for command/s, fn ->
        Model.normalize_command_spec({Cmd, when: true})
      end
    end

    test "a one-arity when: still normalizes" do
      assert {1, Cmd, %{when: pred}} =
               Model.normalize_command_spec({Cmd, when: fn _state -> true end})

      assert is_function(pred, 1)
    end
  end

  describe "command :overrides arity validation" do
    test "a zero-arity overrides: is rejected with a clear error" do
      assert_raise ArgumentError, ~r/`overrides:` for command.*1-arity function.*or a map/s, fn ->
        Model.normalize_command_spec({Cmd, overrides: fn -> %{} end})
      end
    end

    test "a two-arity overrides: is rejected" do
      assert_raise ArgumentError, ~r/`overrides:` for command.*1-arity function.*or a map/s, fn ->
        Model.normalize_command_spec({Cmd, overrides: fn _a, _b -> %{} end})
      end
    end

    test "a non-map, non-function overrides: is rejected" do
      assert_raise ArgumentError, ~r/`overrides:` for command/s, fn ->
        Model.normalize_command_spec({Cmd, overrides: [foo: 1]})
      end
    end

    test "a one-arity overrides: and a map overrides: both normalize" do
      assert {1, Cmd, %{overrides: fun}} =
               Model.normalize_command_spec({Cmd, overrides: fn _state -> %{} end})

      assert is_function(fun, 1)

      assert {1, Cmd, %{overrides: %{x: 1}}} =
               Model.normalize_command_spec({Cmd, overrides: %{x: 1}})
    end
  end

  describe "retired :with key validation" do
    test "a spec with :with key is rejected with a message naming overrides:" do
      assert_raise ArgumentError,
                   ~r/`with:` was renamed `overrides:`/,
                   fn ->
                     Model.normalize_command_spec({Cmd, with: %{}})
                   end
    end

    test "a use PropertyDamage.Command with: default is rejected" do
      assert_raise ArgumentError,
                   ~r/`with:` was renamed `overrides:`/,
                   fn ->
                     Model.normalize_command_spec(
                       PropertyDamage.GeneratorValidationTest.CmdWithWith
                     )
                   end
    end
  end

  describe "branching bounds validation" do
    test "min_prefix_length > max_commands is rejected (would never terminate)" do
      assert_raise ArgumentError, ~r/min_prefix_length.*max_commands/, fn ->
        Options.validate_run!(
          model: PropertyDamage.Test.ExecutorModel,
          adapter: PropertyDamage.Test.SimpleAdapter,
          max_commands: 3,
          branching: [min_prefix_length: 10]
        )
      end
    end

    test "min_prefix_length <= max_commands is accepted" do
      opts =
        Options.validate_run!(
          model: PropertyDamage.Test.ExecutorModel,
          adapter: PropertyDamage.Test.SimpleAdapter,
          max_commands: 20,
          branching: [min_prefix_length: 3]
        )

      assert Keyword.get(opts, :max_commands) == 20
    end
  end
end
