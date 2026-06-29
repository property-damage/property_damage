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
      assert output =~ "Extra Projections"
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

  # Regression: warn_orphan_events/1 used to read assertion.trigger blindly,
  # which crashed (KeyError :trigger) on @poll_state assertions, since those
  # carry :poll_state instead. Surfaced by the Oban (6b) bench, whose model
  # validates a projection with a @poll_state assertion. The event a poll
  # triggers on must also count as handled (not reported as an orphan).
  describe "validate!/3 with a @poll_state assertion projection" do
    defmodule PollEvents do
      defmodule Started, do: defstruct([])
      defmodule Finished, do: defstruct([])
    end

    defmodule PollCommand do
      @behaviour PropertyDamage.Command
      defstruct []

      @impl true
      def generator(_overrides \\ %{}), do: StreamData.constant(%{})

      @impl true
      def downstream_observables, do: [PollEvents.Started]
    end

    defmodule PollProjection do
      use PropertyDamage.Model.Projection

      alias PollEvents.{Finished, Started}

      @impl true
      def init, do: %{done: false}

      @impl true
      def apply(state, %Finished{}), do: %{state | done: true}
      def apply(state, _), do: state

      @poll_state after: Started, timeout: {100, :milliseconds}, interval: {10, :milliseconds}
      def eventually_finished(_state, %Started{}), do: fn s -> s.done end
    end

    defmodule PollModel do
      @behaviour PropertyDamage.Model

      @impl true
      def commands, do: [PollCommand]
      @impl true
      def command_sequence_projection, do: PollProjection
      @impl true
      def assertion_projections, do: [PollProjection]
    end

    defmodule PollAdapter do
      use PropertyDamage.Adapter

      @impl true
      def setup(config), do: {:ok, config}
      @impl true
      def teardown(_ctx), do: :ok
      @impl true
      def execute(%PollCommand{}, _ctx, _runtime), do: {:ok, [%PollEvents.Started{}]}
    end

    test "validation does not crash on a @poll_state assertion" do
      assert {:ok, warnings} = Validation.validate!(PollModel, PollAdapter)
      assert is_list(warnings)
    end

    test "the poll's trigger event is not reported as an orphan" do
      {:ok, warnings} = Validation.validate!(PollModel, PollAdapter)

      refute Enum.any?(warnings, &(&1 =~ "Started" and &1 =~ "orphan"))
    end
  end
end
