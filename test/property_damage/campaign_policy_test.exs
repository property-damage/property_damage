defmodule PropertyDamage.CampaignPolicyTest do
  # The run loop's policy, driven with a fake run step: no model, no adapter,
  # no scheduler. The fake records the run numbers it sees and the
  # accumulator it receives, so each test reads the policy off those calls.
  use ExUnit.Case, async: true

  alias PropertyDamage.Campaign
  alias PropertyDamage.Campaign.Context
  alias PropertyDamage.{Expansion, FailureReport, Generator, Options, Progress.Reporter, Target}
  alias PropertyDamage.{ReplayArtifact, Sequence}
  alias PropertyDamage.Shrinker.Config, as: ShrinkerConfig

  defmodule FakeCommand do
    defstruct []
  end

  defp target, do: %Target{adapter: FakeAdapter, name: "fake", index: 0}

  defp acc do
    %{
      fires: %{},
      compare_counts: %{},
      tracker: nil,
      total_commands: 0,
      setup_commands: 0,
      teardown_commands: 0,
      expansion_counts: %{"fake" => %{}},
      samples: [],
      last_run: nil
    }
  end

  # A context whose run step is `step`. The loop reads the model's invariant
  # catalog when every run passes, so the model is a real test model; it is
  # never run.
  defp context(step, fields \\ []) do
    base = %Context{
      model: PropertyDamage.Test.MinimalModel,
      targets: [target()],
      target: target(),
      reporter: Reporter.new([]),
      seed: 7,
      max_runs: 3,
      run_once: step
    }

    struct!(base, fields)
  end

  # A step that passes, adds the run's number to `total_commands` and
  # reports every call to the test process.
  defp passing_step(test_pid) do
    fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})
      {:pass, %{acc | total_commands: acc.total_commands + run_number + 1}}
    end
  end

  defp seen_runs(acc \\ []) do
    receive do
      {:run, number, seen_acc} -> seen_runs([{number, seen_acc} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "runs exactly max_runs runs when every run passes and returns the stats" do
    ctx = context(passing_step(self()), max_runs: 4)

    assert {:ok, stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0, 1, 2, 3]
    assert stats.runs == 4
    assert stats.seed == 7
    assert stats.total_commands == 1 + 2 + 3 + 4
    assert stats.targets == [%{index: 0, name: "fake"}]
    refute Map.has_key?(stats, :replay)
    refute Map.has_key?(stats, :metrics)
  end

  test "first_run offsets the run numbers, so a single run n sees exactly run n" do
    ctx = context(passing_step(self()), first_run: 4, max_runs: 1)

    assert {:ok, _stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [4]
  end

  test "first_run shifts the whole window of max_runs runs" do
    ctx = context(passing_step(self()), first_run: 2, max_runs: 3)

    assert {:ok, _stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [2, 3, 4]
  end

  test "stops at the first failing run, calls the step no further and returns the error" do
    test_pid = self()

    step = fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})
      if run_number == 1, do: {:error, :found_at_one}, else: {:pass, acc}
    end

    assert Campaign.loop(context(step, max_runs: 5), acc()) == {:error, :found_at_one}

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0, 1]
  end

  test "a failure on the first run is returned with no further call" do
    test_pid = self()

    step = fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})
      {:error, :first}
    end

    assert Campaign.loop(context(step), acc()) == {:error, :first}
    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0]
  end

  test "threads each pass's accumulator into the next call" do
    test_pid = self()

    step = fn _ctx, run_number, acc ->
      send(test_pid, {:run, run_number, acc})

      {:pass,
       %{
         acc
         | total_commands: acc.total_commands + 10,
           fires: Map.update(acc.fires, :check, 1, &(&1 + 1)),
           last_run: %{run_number: run_number}
       }}
    end

    assert {:ok, stats} = Campaign.loop(context(step, max_runs: 3), acc())

    calls = seen_runs()
    assert Enum.map(calls, &elem(&1, 0)) == [0, 1, 2]
    assert Enum.map(calls, fn {_, seen} -> seen.total_commands end) == [0, 10, 20]
    assert Enum.map(calls, fn {_, seen} -> seen.fires end) == [%{}, %{check: 1}, %{check: 2}]

    assert Enum.map(calls, fn {_, seen} -> seen.last_run end) == [
             nil,
             %{run_number: 0},
             %{run_number: 1}
           ]

    assert stats.total_commands == 30
    assert stats.check_fires == %{check: 3}
  end

  test "a context with a replay marks a passing run as not reproduced" do
    replay = %{sequence: nil, expansion: nil}
    ctx = context(passing_step(self()), first_run: 0, max_runs: 1, replay: replay)

    assert {:ok, stats} = Campaign.loop(ctx, acc())

    assert Enum.map(seen_runs(), &elem(&1, 0)) == [0]
    assert stats.replay == :not_reproduced
  end

  describe "latency budget" do
    defp timed_acc(elapsed_us) do
      sample = %{"fake" => %{timings: [{FakeCommand, elapsed_us}]}}

      %{
        acc()
        | samples: [sample],
          last_run: %{
            sequence: %PropertyDamage.Sequence{},
            run_seed: 7,
            run_number: 0,
            results: [%{}]
          }
      }
    end

    defp latency_ctx(budget_ms) do
      context(passing_step(self()),
        max_runs: 1,
        latency: true,
        latency_budget: [warmup: 0, p95: [max: {budget_ms, :milliseconds}]]
      )
    end

    test "a sample under the budget finishes with the metrics in the stats" do
      assert {:ok, stats} = Campaign.loop(latency_ctx(10), timed_acc(5_000))

      assert stats.metrics["fake"].commands == 1
      assert stats.metrics["fake"].p95 == 5_000
    end

    test "a sample over the budget returns a latency report instead of stats" do
      assert {:error, %FailureReport{} = report} =
               Campaign.loop(latency_ctx(10), timed_acc(50_000))

      assert report.report_kind == :latency_exceeded
      assert report.variant == %{name: "fake", index: 0}
    end
  end

  # The loop's own run step, on a model small enough to need no fake: it
  # draws a sequence of `Tap` commands and hands each to an adapter that
  # reports it to the test process.
  describe "the campaign's own run step" do
    defmodule Tap do
      use PropertyDamage.Command
      defstruct [:n]

      @impl true
      def generator(overrides \\ %{}) do
        %{n: StreamData.integer(0..9)}
        |> Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
    end

    defmodule Quiet do
      use PropertyDamage.Model.Projection

      @impl true
      def init, do: %{}

      @impl true
      def apply(state, _event), do: state
    end

    defmodule Tripwire do
      use PropertyDamage.Model.Projection

      @impl true
      def init, do: %{}

      @impl true
      def apply(state, _event), do: state

      @check every: 1
      def assert_never(_state, _cmd_or_event), do: PropertyDamage.fail!("tripped")
    end

    defmodule PassingModel do
      use PropertyDamage.Model

      @impl true
      def commands, do: [Tap]

      @impl true
      def command_sequence_projection, do: Quiet

      @impl true
      def check_projections, do: [Quiet]
    end

    defmodule FailingModel do
      use PropertyDamage.Model

      @impl true
      def commands, do: [Tap]

      @impl true
      def command_sequence_projection, do: Quiet

      @impl true
      def check_projections, do: [Tripwire]
    end

    defmodule TapAdapter do
      use PropertyDamage.Adapter

      @impl true
      def setup(config), do: {:ok, config}

      @impl true
      def teardown(_context), do: :ok

      @impl true
      def execute(%Tap{} = command, %{pid: pid}, _runtime) do
        send(pid, {:tapped, command})
        {:ok, []}
      end
    end

    defp tapped(taps \\ []) do
      receive do
        {:tapped, command} -> tapped([command | taps])
      after
        0 -> Enum.reverse(taps)
      end
    end

    defp real_context(model, fields) do
      {:ok, [target]} = Options.validate_targets([{TapAdapter, config: %{pid: self()}}])
      test_pid = self()

      base = %Context{
        model: model,
        targets: [target],
        all_targets: [target],
        target_entries: [Target.to_entry(target)],
        target: target,
        reporter: Reporter.new([]),
        seed: 7,
        run_nonce: 1,
        max_runs: 1,
        max_commands: 3,
        generator: Generator.generate_sequence(model, max_commands: 3),
        shrink: false,
        shrinker_config: ShrinkerConfig.new(),
        replay_dir: false,
        on_failure: &send(test_pid, {:on_failure, &1})
      }

      struct!(base, fields)
    end

    test "a failing run goes through the failure handler and ends the loop with its report" do
      ctx = real_context(FailingModel, max_runs: 3)

      assert {:error, %FailureReport{} = report} = Campaign.loop(ctx, acc())

      assert FailureReport.seed(report) == 7
      assert FailureReport.run_number(report) == 1
      assert report.report_kind == :check_failed
      assert_received {:on_failure, ^report}

      # The first run's commands only: no second run followed the failure.
      assert length(tapped()) <= 3
    end

    test "a passing run executes the sequence the seed draws" do
      ctx = real_context(PassingModel, max_runs: 1)
      drawn = Generator.generate_value(ctx.generator, Generator.run_seed(7, 0))

      assert {:ok, %{runs: 1}} = Campaign.loop(ctx, acc())

      assert tapped() == Sequence.to_list(drawn)
      assert Sequence.to_list(drawn) != []
    end

    test "a replay executes the artifact's sequence instead of one the seed draws" do
      recorded =
        Sequence.linear([%Tap{n: 91}, %Tap{n: 92}])

      {:ok, [target]} = Options.validate_targets([{TapAdapter, config: %{pid: self()}}])
      replay = %{sequence: recorded, expansion: Expansion.identity(recorded, [target])}
      ctx = real_context(PassingModel, replay: replay)

      assert {:ok, %{replay: :not_reproduced}} = Campaign.loop(ctx, acc())

      assert tapped() == [%Tap{n: 91}, %Tap{n: 92}]
    end

    test "a replay of a failing run runs the artifact's sequence and says it reproduced" do
      {:error, %FailureReport{replay: term} = found} =
        Campaign.loop(real_context(FailingModel, []), acc())

      tapped()
      sequence = ReplayArtifact.sequence(term, [])

      replay = %{
        term: term,
        path: "found.pd",
        sequence: sequence,
        expansion: ReplayArtifact.expansion(term, sequence, nil, [])
      }

      assert {:error, %FailureReport{} = report} =
               Campaign.loop(real_context(FailingModel, replay: replay), acc())

      assert report.replay_status == :reproduced
      assert report.replay_path == "found.pd"

      assert FailureReport.shrunk_sequence(report) |> Sequence.to_list() ==
               FailureReport.shrunk_sequence(found) |> Sequence.to_list()

      assert tapped() != []
    end
  end
end
