defmodule PropertyDamage.ValidationTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Validation

  alias PropertyDamage.Test.{
    ExecutorModel,
    FullModel,
    SimpleAdapter,
    SimpleInjectorAdapter,
    UnloadedEmitsInjector
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

  describe "validate!/3 command callbacks" do
    defmodule NoGeneratorCommand do
      # A loaded command module that deliberately omits generator/1.
      defstruct []
    end

    defmodule NoGeneratorProjection do
      @behaviour PropertyDamage.Model.Projection

      @impl true
      def init, do: %{}

      @impl true
      def apply(state, _), do: state
    end

    defmodule NoGeneratorModel do
      @behaviour PropertyDamage.Model

      @impl true
      def commands, do: [NoGeneratorCommand]

      @impl true
      def command_sequence_projection, do: NoGeneratorProjection

      @impl true
      def assertion_projections, do: []
    end

    test "raises when a command is missing generator/1" do
      assert_raise ArgumentError, ~r/generator\/1/, fn ->
        Validation.validate!(NoGeneratorModel, SimpleAdapter)
      end
    end
  end

  # Regression (W4A/A1): a nemesis module listed directly in commands/0 — the
  # usage taught by guides/chaos_engineering.md and every nemesis moduledoc —
  # generates via new!/2 (DR-031), not generator/1, and does not `use
  # PropertyDamage.Command`. Validation used to require generator/1 on every
  # command module unconditionally, so it raised "missing required callback
  # generator/1" before generation ever ran. It must instead require the
  # callback the generation path actually calls (new!/2) for nemesis modules.
  describe "validate!/3 with a nemesis module in commands/0" do
    defmodule NemesisEvents do
      defmodule Touched, do: defstruct([])
    end

    defmodule NemesisRegularCommand do
      use PropertyDamage.Command, observables: [NemesisEvents.Touched]
      defstruct []

      @impl true
      def generator(overrides \\ %{}) do
        %{}
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end

    defmodule NemesisProjection do
      use PropertyDamage.Model.Projection

      @impl true
      def init, do: %{}

      @impl true
      def apply(state, _), do: state
    end

    defmodule NemesisModel do
      @behaviour PropertyDamage.Model

      @impl true
      def commands do
        [
          {NemesisRegularCommand, weight: 5},
          {PropertyDamage.Nemesis.NetworkLatency, weight: 1}
        ]
      end

      @impl true
      def command_sequence_projection, do: NemesisProjection

      @impl true
      def assertion_projections, do: []
    end

    test "validates a nemesis command via new!/2 instead of generator/1" do
      assert {:ok, warnings} = Validation.validate!(NemesisModel, SimpleAdapter)
      assert is_list(warnings)
    end

    test "validate_command_list!/1 accepts a nemesis command" do
      assert :ok = Validation.validate_command_list!(NemesisModel)
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

    test "covers injectable events even when the injector module is not yet loaded" do
      # Regression: an injector adapter is passed by name and may never have been
      # called, so its module can be unloaded when validation runs.
      # function_exported?/3 reports false for an unloaded module and does not
      # load it, which made collect_emitted_events see no @emits and report every
      # injectable event uncovered. collect_emitted_events must Code.ensure_loaded?
      # first. FullModel.injectable_events == UnloadedEmitsInjector.@emits, so a
      # false "uncovered" would raise here.
      :code.purge(UnloadedEmitsInjector)
      :code.delete(UnloadedEmitsInjector)
      refute :erlang.module_loaded(UnloadedEmitsInjector)

      assert {:ok, _warnings} =
               Validation.validate!(FullModel, SimpleAdapter,
                 injector_adapters: [UnloadedEmitsInjector]
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
      use PropertyDamage.Command, observables: [PollEvents.Started]
      defstruct []

      @impl true
      def generator(_overrides \\ %{}), do: StreamData.constant(%{})
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
