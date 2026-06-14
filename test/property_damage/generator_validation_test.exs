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
