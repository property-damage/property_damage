defmodule PropertyDamage.ReplayTest do
  use ExUnit.Case, async: false

  alias PropertyDamage.{Executor, FailureReport, Replay, Sequence}

  # ----------------------------------------------------------------------------
  # Self-contained fixture: a counter that fails its invariant on the 3rd bump.
  # Deterministic, linear, no refs — ideal for proving replay round-trips.
  # ----------------------------------------------------------------------------

  defmodule Counted do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Bump do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Counter do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %Counted{amount: n}), do: %{state | count: state.count + n}
    def apply(state, _), do: state

    @check every: 1
    def count_bounded(state, _cmd_or_event) do
      if state.count >= 3 do
        PropertyDamage.fail!("count exceeded bound", count: state.count)
      end
    end
  end

  defmodule CounterAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, %{config: config}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Bump{}, _context, _runtime), do: {:ok, [%Counted{amount: 1}]}
  end

  defmodule CounterModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter
  end

  # A setup command and a teardown command for the counter.
  defmodule Prepare do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct [:tag]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: StreamData.constant("default")}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Release do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # The counter with one setup command and one teardown command.
  defmodule LifecycleCounterModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    alias PropertyDamage.ReplayTest.{Bump, Counter, Prepare, Release}

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter

    @impl true
    def setup_each, do: [{Prepare, overrides: %{tag: "fixture"}}]

    @impl true
    def teardown_each, do: [Release]
  end

  # The counter adapter, reporting its setup/1 config, every command it
  # executes and its teardown/1 to the pid carried in the config.
  defmodule LifecycleCounterAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      send(config.test_pid, {:lifecycle, :setup, config})
      {:ok, %{config: config}}
    end

    @impl true
    def teardown(context) do
      send(context.config.test_pid, {:lifecycle, :teardown, context.config})
      :ok
    end

    @impl true
    def execute(command, context, _runtime) do
      send(context.config.test_pid, {:lifecycle, :execute, command})

      case command do
        %Bump{} -> {:ok, [%Counted{amount: 1}]}
        _fixture -> {:ok, []}
      end
    end
  end

  # Run the failing sequence through the real engine and package the result as
  # a FailureReport, exactly as the run loop would.
  defp recorded_failure do
    sequence = Sequence.linear([%Bump{}, %Bump{}, %Bump{}])

    {:ok, result} = Executor.run(sequence, CounterModel, CounterAdapter, [])

    refute result.success
    assert result.failed_at_index == 2

    failure =
      FailureReport.new(
        seed: 0,
        run_number: 1,
        original_sequence: sequence,
        shrunk_sequence: sequence,
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        event_log: result.event_log,
        projections: result.projections,
        projections_before: result.projections_before,
        model: CounterModel,
        targets: [{CounterAdapter, []}]
      )

    {failure, result}
  end

  describe "run/2 round-trip" do
    test "a recorded failure replays to the identical step sequence and state" do
      {failure, result} = recorded_failure()

      {:ok, steps} = Replay.run(failure)

      # Every command up to and including the failure was executed
      assert length(steps) == 3
      assert Enum.map(steps, & &1.index) == [0, 1, 2]

      # The first two steps pass, the third fails its invariant
      assert Enum.at(steps, 0).result == :ok
      assert Enum.at(steps, 1).result == :ok
      assert {:check_failed, :count_bounded, _exception} = Enum.at(steps, 2).result

      # Replay reaches the same failure state the original run recorded
      assert Enum.at(steps, 2).projections == result.projections
      assert Enum.at(steps, 2).projections[Counter] == %{count: 3}

      # And actually executed steps (vs. the old code, which never ran one):
      # each Bump produced its Counted event in order
      assert Enum.map(steps, fn s -> Enum.map(s.events, & &1.amount) end) == [[1], [1], [1]]
    end

    test "stop_on_failure: false runs past the failure to the end" do
      {failure, _result} = recorded_failure()

      {:ok, steps} = Replay.run(failure, stop_on_failure: false)

      assert length(steps) == 3
      # The invariant stays violated for the final step too
      assert {:check_failed, _, _} = Enum.at(steps, 2).result
    end
  end

  describe "interactive stepping" do
    test "step/1 advances one command at a time and exposes intermediate state" do
      {failure, _result} = recorded_failure()

      {:ok, session} = Replay.start(failure)
      assert session.status == :ready
      # Projections are initialized before the first command runs
      assert Replay.current_state(session)[Counter] == %{count: 0}

      {:ok, session, step0} = Replay.step(session)
      assert step0.index == 0
      assert step0.result == :ok
      assert step0.projections_before[Counter] == %{count: 0}
      assert step0.projections[Counter] == %{count: 1}

      {:ok, session, step1} = Replay.step(session)
      assert step1.projections[Counter] == %{count: 2}
      assert step1.result == :ok

      {:ok, session, step2} = Replay.step(session)
      assert step2.index == 2
      assert {:check_failed, :count_bounded, _} = step2.result
      assert step2.projections[Counter] == %{count: 3}
      assert session.status == :failed

      # No commands remain
      assert {:done, _} = Replay.step(session)

      assert :ok = Replay.stop(session)
    end

    test "step_to/2 jumps to the failure index" do
      {failure, _result} = recorded_failure()

      {:ok, session} = Replay.start(failure)
      {:ok, session, steps} = Replay.step_to(session, failure.failed_at_index)

      assert session.current_index == failure.failed_at_index
      assert List.last(steps).index == 2
      assert {:check_failed, _, _} = List.last(steps).result
      Replay.stop(session)
    end

    test "peek/2 returns commands without executing" do
      {failure, _result} = recorded_failure()
      {:ok, session} = Replay.start(failure)

      assert {:ok, %Bump{}} = Replay.peek(session, 0)
      assert {:error, :out_of_bounds} = Replay.peek(session, 99)
      # peeking did not advance the session
      assert session.current_index == -1
      Replay.stop(session)
    end
  end

  describe "guards" do
    test "missing model" do
      failure = %FailureReport{model: nil, targets: [{CounterAdapter, []}]}
      assert {:error, :missing_model} = Replay.start(failure)
    end

    test "missing adapter" do
      failure = %FailureReport{model: CounterModel, targets: []}
      assert {:error, :missing_adapter} = Replay.start(failure)
    end

    test "branching sequences are not steppable" do
      branching = %Sequence{prefix: [%Bump{}], branches: [[%Bump{}], [%Bump{}]], suffix: []}

      failure = %FailureReport{
        model: CounterModel,
        targets: [{CounterAdapter, []}],
        trace: PropertyDamage.RunTrace.new(plan: branching)
      }

      assert {:error, :branching_replay_unsupported} = Replay.start(failure)
      assert {:error, :branching_replay_unsupported} = Replay.run(failure)
    end
  end

  describe "formatting" do
    test "format_history renders each step with its outcome" do
      {failure, _result} = recorded_failure()
      {:ok, steps} = Replay.run(failure)

      output = Replay.format_history(steps)
      assert output =~ "[0] Bump -> OK"
      assert output =~ "[2] Bump -> FAILED (count_bounded)"
      assert output =~ "Events: Counted"
    end
  end

  # The counter's failure, recorded with the setup and teardown commands of
  # LifecycleCounterModel.
  defp recorded_lifecycle_failure do
    sequence = %{
      Sequence.linear([%Bump{}, %Bump{}, %Bump{}])
      | setup: [%Prepare{tag: "fixture"}],
        teardown: [%Release{}]
    }

    {:ok, result} =
      Executor.run(sequence, LifecycleCounterModel, CounterAdapter,
        setup_commands: sequence.setup,
        teardown_commands: sequence.teardown
      )

    refute result.success

    FailureReport.new(
      seed: 0,
      run_number: 1,
      original_sequence: sequence,
      shrunk_sequence: sequence,
      failed_at_index: result.failed_at_index,
      failure_reason: result.failure_reason,
      event_log: result.event_log,
      projections: result.projections,
      projections_before: result.projections_before,
      model: LifecycleCounterModel,
      targets: [{CounterAdapter, []}]
    )
  end

  defp lifecycle_messages(acc \\ []) do
    receive do
      {:lifecycle, _, _} = message -> lifecycle_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the replay session lifecycle" do
    test "Replay.run sets the target up with its config, runs the setup commands before step 0 and the teardown commands before teardown/1" do
      pid = self()
      failure = recorded_lifecycle_failure()
      assert failure.setup_commands == [%Prepare{tag: "fixture"}]

      {:ok, steps} =
        Replay.run(failure, targets: [{LifecycleCounterAdapter, config: %{test_pid: pid}}])

      # Steps index the roots only.
      assert Enum.map(steps, & &1.index) == [0, 1, 2]

      assert [
               {:lifecycle, :setup, %{test_pid: ^pid}},
               {:lifecycle, :execute, %Prepare{tag: "fixture"}},
               {:lifecycle, :execute, %Bump{}},
               {:lifecycle, :execute, %Bump{}},
               {:lifecycle, :execute, %Bump{}},
               {:lifecycle, :execute, %Release{}},
               {:lifecycle, :teardown, %{test_pid: ^pid}}
             ] = lifecycle_messages()
    end

    test "a session runs the setup commands in start/2 and the teardown commands in stop/1" do
      pid = self()
      failure = recorded_lifecycle_failure()

      {:ok, session} =
        Replay.start(failure, targets: [{LifecycleCounterAdapter, config: %{test_pid: pid}}])

      assert session.current_index == -1

      assert [
               {:lifecycle, :setup, %{test_pid: ^pid}},
               {:lifecycle, :execute, %Prepare{tag: "fixture"}}
             ] = lifecycle_messages()

      {:ok, session, step} = Replay.step(session)
      assert step.index == 0
      assert [{:lifecycle, :execute, %Bump{}}] = lifecycle_messages()

      :ok = Replay.stop(session)

      assert [
               {:lifecycle, :execute, %Release{}},
               {:lifecycle, :teardown, %{test_pid: ^pid}}
             ] = lifecycle_messages()
    end
  end
end
