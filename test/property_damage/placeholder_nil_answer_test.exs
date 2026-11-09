defmodule PropertyDamage.PlaceholderNilAnswerTest do
  # A system may answer `nil` for an `external()` field. The placeholder then
  # resolves to `nil` and a later command receives `nil`. An event that lacks
  # the field leaves the placeholder unresolved, and the run reports it.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Failure, FailureReport, Generator, Placeholder, PlaceholderRegistry}
  alias PropertyDamage.Sequence
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.SetupCommands
  alias PropertyDamage.Test.SetupCommands.{CreateUser, Login}
  alias PropertyDamage.Test.StepRun

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct [:label, id: external(), ids: %{order: external()}]
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct [:label]
    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{label: StreamData.constant("x")}, overrides)
      )
    end
  end

  defmodule Use do
    @behaviour PropertyDamage.Command
    defstruct [:target]
    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{target: StreamData.constant(:unset)}, overrides)
      )
    end
  end

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  # The producer answers according to the config: `:answer` is the value of
  # both external fields, and `:lacking` leaves the nested field out.
  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Create{label: label}, %{lacking: true}, _runtime),
      do: {:ok, [%Created{label: label, id: "real", ids: %{}}]}

    def execute(%Create{label: label}, %{answer: answer}, _runtime),
      do: {:ok, [%Created{label: label, id: answer, ids: %{order: answer}}]}

    def execute(%Use{target: target}, %{test_pid: pid}, _runtime) do
      send(pid, {:used, target})
      {:ok, []}
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model
    @impl true
    def commands, do: [Create, Use]
    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{label: l}, _state), do: [%Created{label: l}]
    def simulate(_command, _state), do: []
  end

  defp run_root(path, config) do
    placeholder = Placeholder.new_at(Created, path, Position.prefix(0), 0)
    registry = PlaceholderRegistry.new() |> PlaceholderRegistry.register(placeholder)

    sequence =
      [%Create{label: "x"}, %Use{target: placeholder}]
      |> Sequence.linear()
      |> Sequence.with_registry(registry)

    StepRun.run(sequence, Model, Adapter, config: Map.put(config, :test_pid, self()))
  end

  describe "a root producer" do
    @tag :known_defect
    test "answering nil resolves the placeholder, and the consumer receives nil" do
      assert {:ok, result} = run_root([:id], %{answer: nil})

      assert result.failed_at_index == nil
      assert_received {:used, nil}
    end

    @tag :known_defect
    test "answering nil at a nested path resolves the placeholder too" do
      assert {:ok, result} = run_root([:ids, :order], %{answer: nil})

      assert result.failed_at_index == nil
      assert_received {:used, nil}
    end

    test "answering a value still hands the consumer that value" do
      assert {:ok, result} = run_root([:id], %{answer: "real"})

      assert result.failed_at_index == nil
      assert_received {:used, "real"}
    end

    test "an event that lacks the field leaves the consumer's argument unresolved" do
      assert {:ok, result} = run_root([:ids, :order], %{lacking: true})

      assert result.failed_at_index == 1

      assert %Failure{type: %Failure.Framework{kind: :placeholder_resolution, detail: detail}} =
               result.failure_reason

      assert detail =~ "Unresolved placeholder at [:ids, :order]"
      refute_received {:used, _target}
    end
  end

  describe "a setup producer" do
    defp run_setup(config) do
      recorder = start_recorder()

      model =
        SetupCommands.define_model!(
          Module.concat(__MODULE__, "Setup#{System.unique_integer([:positive])}"),
          setup: SetupCommands.standard_setup()
        )

      result =
        PropertyDamage.run(
          model: model,
          targets: [SetupCommands.target("a", recorder, config)],
          max_runs: 1,
          max_commands: 3,
          seed: 4_242,
          shrink: false,
          validate: false
        )

      {result, recorder}
    end

    @tag :known_defect
    test "answering nil resolves the placeholder, and the next setup command receives nil" do
      {result, recorder} = run_setup(%{drop_id: true})

      assert {:ok, _stats} = result

      assert [%Login{user_id: nil}] =
               for(%Login{} = login <- SetupCommands.executed(recorded(recorder), "a"), do: login)
    end

    test "an event answer that is absent fails the setup as an unresolved placeholder" do
      {result, recorder} = run_setup(%{no_event: true})

      assert {:error, %FailureReport{} = report} = result

      assert %Failure{
               type: %Failure.Setup{
                 cause: :unresolved_placeholder,
                 field: [:id],
                 setup_index: 0,
                 command: %CreateUser{}
               }
             } = FailureReport.failure_reason(report)

      refute Enum.any?(SetupCommands.executed(recorded(recorder), "a"), &match?(%Login{}, &1))
    end
  end
end
