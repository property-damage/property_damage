defmodule PropertyDamage.ValidationExtendedTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Validation
  alias PropertyDamage.Options

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule ValidCommand do
    defstruct [:id]

    def generator(_overrides \\ %{}), do: StreamData.constant(%{id: 1})
    def events(_cmd, _response), do: []
  end

  defmodule InvalidCommand do
    # Missing required callbacks
    defstruct [:id]
  end

  defmodule ValidProjection do
    @behaviour PropertyDamage.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state
  end

  defmodule ValidModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [{ValidCommand, weight: 10}]
    end

    @impl true
    def state_projection, do: PropertyDamage.ValidationExtendedTest.ValidProjection

    @impl true
    def extra_projections, do: []

    @impl true
    def simulate(_cmd, _state), do: []
  end

  defmodule EmptyModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: []

    @impl true
    def state_projection, do: PropertyDamage.ValidationExtendedTest.ValidProjection

    @impl true
    def extra_projections, do: []
  end

  defmodule InvalidWeightModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [{-5, PropertyDamage.ValidationExtendedTest.ValidCommand}]
    end

    @impl true
    def state_projection, do: PropertyDamage.ValidationExtendedTest.ValidProjection

    @impl true
    def extra_projections, do: []
  end

  defmodule ValidAdapter do
    def setup(_config), do: {:ok, %{}}
    def teardown(_ctx), do: :ok
    def execute(_cmd, _ctx), do: {:ok, %{}}
  end

  # ============================================================================
  # Options.validate_run! Tests (NimbleOptions-based validation)
  # ============================================================================

  describe "Options.validate_run!/1" do
    test "passes with valid options and returns keyword list with defaults" do
      opts = [model: ValidModel, adapter: ValidAdapter]
      validated = Options.validate_run!(opts)

      assert validated[:model] == ValidModel
      assert validated[:adapter] == ValidAdapter
      assert validated[:max_commands] == 50
      assert validated[:max_runs] == 100
    end

    test "raises on missing model" do
      opts = [adapter: ValidAdapter]

      assert_raise NimbleOptions.ValidationError, ~r/required :model option not found/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "raises on missing adapter" do
      opts = [model: ValidModel]

      assert_raise NimbleOptions.ValidationError, ~r/required :adapter option not found/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "raises on invalid max_commands" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_commands: -5]

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "raises on non-integer max_commands" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_commands: "abc"]

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "raises on invalid max_runs" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_runs: 0]

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "raises on invalid seed" do
      opts = [model: ValidModel, adapter: ValidAdapter, seed: -1]

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "accepts valid optional parameters" do
      opts = [
        model: ValidModel,
        adapter: ValidAdapter,
        max_commands: 100,
        max_runs: 50,
        seed: 12345
      ]

      validated = Options.validate_run!(opts)
      assert validated[:max_commands] == 100
      assert validated[:max_runs] == 50
      assert validated[:seed] == 12345
    end
  end

  # ============================================================================
  # validate_command_list! Tests
  # ============================================================================

  describe "Validation.validate_command_list!/1" do
    test "passes with valid model" do
      assert :ok = Validation.validate_command_list!(ValidModel)
    end

    test "raises on empty command list" do
      assert_raise ArgumentError, ~r/No Commands/, fn ->
        Validation.validate_command_list!(EmptyModel)
      end
    end

    test "raises on invalid weight" do
      assert_raise ArgumentError, ~r/Invalid Command Weight/, fn ->
        Validation.validate_command_list!(InvalidWeightModel)
      end
    end
  end

  # ============================================================================
  # validate_command_callbacks! Tests
  # ============================================================================

  describe "Validation.validate_command_callbacks!/1" do
    test "passes with valid command" do
      assert :ok = Validation.validate_command_callbacks!(ValidCommand)
    end

    test "raises on missing callback" do
      assert_raise ArgumentError, ~r/Missing Command Callback/, fn ->
        Validation.validate_command_callbacks!(InvalidCommand)
      end
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "nil model raises helpful error" do
      opts = [model: nil, adapter: ValidAdapter]

      assert_raise NimbleOptions.ValidationError, ~r/:model/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "nil adapter raises helpful error" do
      opts = [model: ValidModel, adapter: nil]

      assert_raise NimbleOptions.ValidationError, ~r/:adapter/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "zero max_commands raises" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_commands: 0]

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_run!(opts)
      end
    end

    test "float max_runs raises" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_runs: 10.5]

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Options.validate_run!(opts)
      end
    end
  end

  # ============================================================================
  # Runtime Warnings Tests
  # ============================================================================

  describe "Validation.runtime_warnings/1" do
    test "returns empty list for good defaults" do
      opts = [model: ValidModel, adapter: ValidAdapter]
      assert Validation.runtime_warnings(opts) == []
    end

    test "warns about low max_runs" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_runs: 5]
      warnings = Validation.runtime_warnings(opts)

      assert length(warnings) == 1
      assert hd(warnings) =~ "max_runs: 5 is very low"
    end

    test "warns about low max_commands" do
      opts = [model: ValidModel, adapter: ValidAdapter, max_commands: 3]
      warnings = Validation.runtime_warnings(opts)

      assert length(warnings) == 1
      assert hd(warnings) =~ "max_commands: 3 is very low"
    end

    test "warns when shrink is false" do
      opts = [model: ValidModel, adapter: ValidAdapter, shrink: false]
      warnings = Validation.runtime_warnings(opts)

      assert length(warnings) == 1
      assert hd(warnings) =~ "shrink: false"
    end

    test "warns when validate is false" do
      opts = [model: ValidModel, adapter: ValidAdapter, validate: false]
      warnings = Validation.runtime_warnings(opts)

      assert length(warnings) == 1
      assert hd(warnings) =~ "validate: false"
    end

    test "accumulates multiple warnings" do
      opts = [
        model: ValidModel,
        adapter: ValidAdapter,
        max_runs: 2,
        max_commands: 2,
        shrink: false
      ]

      warnings = Validation.runtime_warnings(opts)
      assert length(warnings) == 3
    end
  end

  # ============================================================================
  # Model Warnings Tests
  # ============================================================================

  defmodule SingleCommandModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [PropertyDamage.ValidationExtendedTest.ValidCommand]

    @impl true
    def state_projection, do: PropertyDamage.ValidationExtendedTest.ValidProjection

    @impl true
    def extra_projections, do: []
  end

  defmodule UnbalancedWeightModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [
        {100, PropertyDamage.ValidationExtendedTest.ValidCommand},
        {1, PropertyDamage.ValidationExtendedTest.ValidCommand}
      ]
    end

    @impl true
    def state_projection, do: PropertyDamage.ValidationExtendedTest.ValidProjection

    @impl true
    def extra_projections, do: []
  end

  describe "model warnings" do
    test "warns about empty extra projections" do
      {:ok, warnings} = Validation.validate!(ValidModel, ValidAdapter)
      assert Enum.any?(warnings, &(&1 =~ "no extra projections"))
    end

    test "warns about single command" do
      {:ok, warnings} = Validation.validate!(SingleCommandModel, ValidAdapter)
      assert Enum.any?(warnings, &(&1 =~ "only one command"))
    end

    test "warns about unbalanced weights" do
      {:ok, warnings} = Validation.validate!(UnbalancedWeightModel, ValidAdapter)
      assert Enum.any?(warnings, &(&1 =~ "will dominate test sequences"))
    end
  end
end
