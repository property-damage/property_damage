defmodule PropertyDamage.ReportRunRecordTest do
  # What a failure report records about the run it describes, and how the
  # paths that run the failure again use it: the plan's source, the check
  # mode, the failing index of the original run, the campaign a latency
  # budget was judged over, the roots a startup failure ran, the replay call,
  # and the error paths of `shrink_further/2` and `isolate_trigger/2`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Reshrink
  alias PropertyDamage.{FailureReport, Persistence, Replay, Sequence}
  alias PropertyDamage.ReportRunRecordTest.{FlakyAdapter, FlakyModel, StartupFails}
  alias PropertyDamage.Test.Expansion, as: A
  alias PropertyDamage.Test.Lockstep.{GuardedStepModel, StartupModel, StepAdapter, StepModel}

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  @seed 12_345

  defp step(name, config) do
    {StepAdapter, name: name, config: Map.merge(%{name: name}, config)}
  end

  defp run(targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: GuardedStepModel,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 6,
          seed: @seed,
          validate: false,
          replay_dir: false
        ],
        extra
      )
    )
  end

  defmodule StartupFails do
    @moduledoc false
    # A check that fails at startup in every run.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check at: :startup
    def assert_ready(_state, _phase), do: PropertyDamage.fail!("never ready")
  end

  defmodule Bumped do
    @moduledoc false
    defstruct [:n]
  end

  defmodule Bump do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Count do
    @moduledoc false
    # Fails once the adapter's answer reaches the threshold the adapter was
    # given for this execution.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{last: 0}

    @impl true
    def apply(state, %Bumped{n: n}), do: %{state | last: n}
    def apply(state, _), do: state

    @check every: 1
    def below_limit(state, _command_or_event) do
      state.last < 3 or PropertyDamage.fail!("limit reached", last: state.last)
    end
  end

  defmodule FlakyModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Count
  end

  defmodule FlakyAdapter do
    @moduledoc false
    # The first execution of the run answers 1, 2, 3, ... (fails at index 2);
    # every later execution answers 2, 3, ... (fails at index 1).
    use PropertyDamage.Adapter

    @impl true
    def setup(%{agent: agent}) do
      run = Agent.get_and_update(agent, &{&1, &1 + 1})
      {:ok, %{offset: if(run == 0, do: 0, else: 1), calls: :atomics.new(1, [])}}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Bump{}, context, _runtime) do
      call = :atomics.add_get(context.calls, 1, 1)
      {:ok, [%Bumped{n: call + context.offset}]}
    end
  end

  describe "plan source" do
    test "a report of a run without shrinking names its plan as generated, in the report and its trace" do
      assert {:error, %FailureReport{} = report} =
               run([step("a", %{bad_at: 1})], shrink: false)

      assert report.trace.plan_source == :generated
    end
  end

  describe "check mode" do
    test "a report records the run's check mode" do
      assert {:error, report} = run([step("a", %{bad_at: 1})], check_mode: :record)
      assert report.check_mode == :record

      assert {:error, report} = run([step("a", %{bad_at: 1})], shrink: false)
      assert report.check_mode == :halt
    end

    test "shrink_further/2 re-shrinks a :record report under :record" do
      # A startup check failure: under :record the run records it and goes on
      # to execute the roots; under :halt no root executes.
      recorder = start_recorder()
      target = step("a", %{fail_startup: true, recorder: recorder})

      assert {:error, report} =
               run([target], model: StartupModel, check_mode: :record, shrink: false)

      assert report.kind == :check_failed
      Agent.update(recorder, fn _ -> [] end)

      assert {:ok, _further} = PropertyDamage.shrink_further(report, max_iterations: 5)

      entered = for {:enter, "a", index} <- recorded(recorder), do: index
      assert entered != [], "no root executed while re-shrinking a :record report"
    end

    test "a replay of a :record report records the failing check and goes on" do
      assert {:error, report} =
               run([step("a", %{bad_at: 1})], check_mode: :record, shrink: false)

      commands = report |> FailureReport.shrunk_sequence() |> Sequence.command_count()
      assert commands > 2

      {:ok, session} = Replay.start(report)
      {:ok, session, steps} = Replay.step_to(session, commands - 1)
      Replay.stop(session)

      assert length(steps) == commands
      assert [%{check_name: :step_is_good}] = session.exec_state.check_failures
    end

    @tag :tmp_dir
    test "mix pd.reshrink re-shrinks a saved :record report under :record", %{tmp_dir: dir} do
      recorder = start_recorder()
      target = step("a", %{fail_startup: true, recorder: recorder})

      assert {:error, report} =
               run([target], model: StartupModel, check_mode: :record, shrink: false)

      {:ok, path} = Persistence.save(report, dir, filename: "record.pd")
      Agent.update(recorder, fn _ -> [] end)
      out = Path.join(dir, "out.pd")

      capture_io(fn ->
        assert Reshrink.exec([path, "--max-iterations", "5", "--output", out]) ==
                 :ok
      end)

      entered = for {:enter, "a", index} <- recorded(recorder), do: index
      assert entered != [], "no root executed while re-shrinking a :record report"
      assert {:ok, reshrunk} = Persistence.load(out)
      assert reshrunk.check_mode == :record
    end
  end

  describe "the original run's failing index" do
    test "an unshrunk reproduction that fails at another index keeps the original index" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      assert {:error, report} =
               PropertyDamage.run(
                 model: FlakyModel,
                 targets: [{FlakyAdapter, config: %{agent: agent}}],
                 seed: 7,
                 max_runs: 1,
                 max_commands: 6,
                 shrink: false,
                 validate: false,
                 replay_dir: false
               )

      # The reproduction failed at index 1; the exploration run at index 2.
      assert report.failed_at_index == 1
      assert FailureReport.failure_step(report).flattened_index == 1
      assert report.original_failed_at_index == 2
    end
  end

  describe "a latency budget's reproduction" do
    test "names the campaign's seed and max_runs" do
      assert {:error, %FailureReport{kind: :latency_exceeded} = report} =
               PropertyDamage.run(
                 model: StepModel,
                 targets: [step("a", %{hold_ms: 2}), step("b", %{hold_ms: 2})],
                 compare: [converge_within: 30],
                 max_runs: 3,
                 max_commands: 2,
                 seed: @seed,
                 validate: false,
                 replay_dir: false,
                 latency: [warmup: 1, p95: [max_ratio: 1.0e-9]]
               )

      command = FailureReport.reproduction_command(report)
      assert command =~ "seed: #{@seed}"
      assert command =~ "max_runs: 3"
      assert command =~ "warmup: 1"
      refute command =~ "max_runs: 1"
    end

    test "a failure of another kind reproduces one run" do
      assert {:error, report} = run([step("a", %{bad_at: 1})], shrink: false, latency: true)
      assert FailureReport.reproduction_command(report) =~ "max_runs: 1"
    end
  end

  describe "a startup check failure" do
    test "lists and counts no root in either expansion field" do
      model =
        A.define_model!(PropertyDamage.ReportRunRecordTest.StartupExpansionModel,
          commands: [A.Pay],
          expansions: [{A.Pay, &A.pay_expansions/2}],
          checks: [A.Ledger, StartupFails]
        )

      target = A.target("solo", start_recorder())

      assert {:error, %FailureReport{} = report} =
               A.run(model, [target], seed: 3, max_runs: 1, max_commands: 6, shrink: false)

      assert report.kind == :check_failed
      assert report.failed_at_index == nil
      assert report.expansions == %{"solo" => []}
      assert report.expansion_counts == %{"solo" => %{}}
    end
  end

  describe "the replay call" do
    test "names a non-default convergence bound" do
      report = %FailureReport{
        model: GuardedStepModel,
        targets: [{StepAdapter, name: "a"}],
        compare: [converge_within: 100],
        replay_path: "dir/GuardedStepModel_seed1.replay.exs"
      }

      assert FailureReport.replay_command(report) =~ "compare: [converge_within: 100]"

      default = %{report | compare: [converge_within: 5_000]}
      refute FailureReport.replay_command(default) =~ "compare:"
    end
  end

  describe "error paths" do
    test "shrink_further/2 names a missing model or target" do
      report = %FailureReport{seed: 1, model: nil, targets: [{StepAdapter, []}]}
      assert {:error, :missing_model_or_target} = PropertyDamage.shrink_further(report)
    end

    test "isolate_trigger/2 refuses a divergence: one target alone cannot diverge" do
      assert {:error, %FailureReport{kind: :diverged} = report} =
               PropertyDamage.run(
                 model: StepModel,
                 targets: [step("a", %{}), step("b", %{behavior: :shift})],
                 compare: [converge_within: 30],
                 max_runs: 1,
                 max_commands: 3,
                 seed: @seed,
                 validate: false,
                 replay_dir: false
               )

      assert {:error, :not_applicable} = PropertyDamage.Analysis.isolate_trigger(report)
    end
  end
end
