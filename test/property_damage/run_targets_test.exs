defmodule PropertyDamage.RunTargetsTest do
  # `PropertyDamage.run/1` runs one target or several through the lockstep
  # scheduler and reports every failure in one shape that names the target it
  # happened in.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{EventQueue, Failure, FailureReport, Generator, Persistence, Sequence}
  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.RunResult
  alias PropertyDamage.RunTargetsTest.{Sink, SinkModel}

  alias PropertyDamage.Test.Lockstep.{
    GuardedStepModel,
    Ledger,
    PolledModel,
    StartupModel,
    Step,
    StepAdapter,
    StepModel,
    Stepped
  }

  @seed 12_345
  @run_nonce 99

  defp step(name, config \\ %{}) do
    {StepAdapter, name: name, config: Map.merge(%{name: name}, config)}
  end

  defp run(targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: StepModel,
          targets: targets,
          max_runs: 1,
          max_commands: 3,
          seed: @seed,
          validate: false
        ],
        extra
      )
    )
  end

  defp generated(model, seed, run_number, max_commands) do
    model
    |> Generator.generate_sequence(max_commands: max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, run_number))
  end

  describe "a divergence" do
    for concurrency <- [:serial, :parallel] do
      test "is a :diverged report naming the variant, the root and both observations (#{concurrency})" do
        assert {:error, %FailureReport{} = report} =
                 run([step("a"), step("b", %{behavior: :shift})],
                   concurrency: unquote(concurrency)
                 )

        assert report.kind == :diverged
        assert report.variant == %{index: 1, name: "b"}
        assert report.failed_at_index == 0
        assert report.shrink_iterations == 0
        assert FailureReport.shrunk_sequence(report) == report.original_sequence

        assert %Failure{} = reason = report.failure_reason
        assert Failure.kind(reason) == :diverged
        assert Failure.name(reason) == nil

        detail = Failure.detail(reason)
        assert detail.root == 0
        assert {:ok, [%Stepped{value: value}]} = detail.reference_result
        assert detail.divergent_result == {:ok, [%Stepped{value: value + 1}]}
        assert detail.results == %{"a" => detail.reference_result, "b" => detail.divergent_result}
      end
    end

    test "after root 0 reports that root as failed_at_index" do
      assert {:error, report} = run([step("a"), step("b", %{bad_at: 1})])

      assert report.kind == :diverged
      assert report.failed_at_index == 1
      assert Failure.detail(report.failure_reason).root == 1
    end
  end

  describe "agreeing targets" do
    test "pass every run and the stats list the targets" do
      assert {:ok, stats} = run([step("a"), step("b")], max_runs: 3)

      assert stats.runs == 3
      assert stats.seed == @seed
      assert stats.targets == [%{index: 0, name: "a"}, %{index: 1, name: "b"}]
    end
  end

  describe "one target" do
    test "runs the adapter calls and folds the state Executor.run/4 does on the same seed" do
      model = SinkModel
      sequence = generated(model, @seed, 0, 4)

      oracle_recorder = start_recorder()
      {:ok, queue} = EventQueue.start_link()

      {:ok, oracle} =
        with_sink(fn ->
          PropertyDamage.Executor.run(sequence, model, StepAdapter,
            config: %{name: "solo", recorder: oracle_recorder},
            event_queue: queue,
            rng_seed: Generator.run_seed(@seed, 0),
            run_nonce: @run_nonce,
            mint_epoch: 0
          )
        end)

      EventQueue.stop(queue)
      oracle_states = take_states()

      recorder = start_recorder()

      {result, run_states} =
        with_sink(fn ->
          result =
            run([{StepAdapter, name: "solo", config: %{name: "solo", recorder: recorder}}],
              model: model,
              max_commands: 4,
              run_nonce: @run_nonce
            )

          {result, take_states()}
        end)

      assert {:ok, %{runs: 1, targets: [%{index: 0, name: "solo"}]}} = result
      assert oracle.success
      assert Sequence.command_count(sequence) > 0
      assert recorded(recorder) == recorded(oracle_recorder)
      assert run_states == oracle_states
      assert List.last(run_states).commands == Sequence.command_count(sequence)
    end

    test "a planted check failure is a :check_failed report naming variant 0" do
      assert {:error, report} = run([step("solo", %{bad_at: 1})], model: GuardedStepModel)

      assert report.kind == :check_failed
      assert report.variant == %{index: 0, name: "solo"}
      assert report.failed_at_index == 1
      assert Failure.kind(report.failure_reason) == :check_failed

      assert report.targets == [
               PropertyDamage.Target.to_entry(hd(targets!([step("solo", %{bad_at: 1})])))
             ]
    end

    test "an adapter {:error, _} at a command is an :execution_failed report" do
      assert {:error, report} = run([step("solo", %{behavior: :error})])

      assert report.kind == :execution_failed
      assert report.variant == %{index: 0, name: "solo"}
      assert report.failed_at_index == 0

      assert %Failure{type: %Failure.Execution{kind: :adapter_error, detail: :refused}} =
               report.failure_reason
    end
  end

  describe "options" do
    test "the Differential module is gone" do
      # Built at runtime: the removed name appears nowhere in source.
      refute Code.ensure_loaded?(Module.concat(PropertyDamage, "Differential"))
    end

    test "execution: is an option error naming concurrency:" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          run([step("a"), step("b")], execution: :interleaved)
        end

      assert error.message =~ "`execution:`"
      assert error.message =~ "`concurrency:`"
    end

    test "branching: with two targets is an option error" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          run([step("a"), step("b")], branching: [branch_probability: 0.5])
        end

      assert error.message =~ "branching"
      assert error.message =~ "one target"
    end

    test "compare: :performance with concurrency: :parallel is an option error" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          run([step("a"), step("b")], compare: :performance, concurrency: :parallel)
        end

      assert error.message =~ "concurrency"
    end
  end

  describe "failure kinds through run/1" do
    test "a sync check failing only in variant 1 is :check_failed naming it" do
      assert {:error, report} =
               run([step("a"), step("b", %{bad_at: 1})],
                 model: GuardedStepModel,
                 equivalence: PropertyDamage.Comparison.ignore_fields([:mark])
               )

      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 1

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} =
               report.failure_reason
    end

    test "an @eventually timeout is :check_failed" do
      assert {:error, report} =
               run([step("a", %{poll: :deliver}), step("b", %{poll: :never})], model: PolledModel)

      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert Failure.kind(report.failure_reason) == :poll_timeout
    end

    test "a failing :startup check is :check_failed with no failed_at_index" do
      assert {:error, report} =
               run([step("a"), step("b", %{fail_startup: true})], model: StartupModel)

      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == nil
    end

    test "a setup error in variant 1 is :setup_failed, never shrunk, variant 0 torn down" do
      assert {:error, report} =
               run([step("a", %{test_pid: self()}), step("b", %{setup_result: :error})],
                 max_runs: 3
               )

      assert report.kind == :setup_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == nil
      assert report.shrink_iterations == 0
      assert %Failure{} = report.failure_reason
      assert Failure.kind(report.failure_reason) == :setup_failed
      assert Failure.detail(report.failure_reason) == :no_backend

      assert [{:setup, "a", setup_a}] = take_messages(:setup)
      assert [{:teardown, "a", ^setup_a}] = take_messages(:teardown)
    end

    test "a raise at a command in variant 1 is :execution_failed" do
      assert {:error, report} = run([step("a"), step("b", %{behavior: :raise})])

      assert report.kind == :execution_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 0
      assert Failure.kind(report.failure_reason) == :adapter_error
    end

    test "two targets that answer the same {:error, _} continue and pass" do
      assert {:ok, %{runs: 2}} =
               run([step("a", %{behavior: :error}), step("b", %{behavior: :error})], max_runs: 2)
    end
  end

  describe "progress" do
    test "the terminal RunResult carries the report's kind and variant" do
      test_pid = self()
      on_progress = fn progress -> send(test_pid, {:progress, progress}) end

      assert {:error, report} =
               run([step("a"), step("b", %{behavior: :shift})], on_progress: on_progress)

      assert %Progress{data: %RunResult{outcome: :error} = result} = last_progress()
      assert result.kind == :diverged
      assert result.variant == %{index: 1, name: "b"}
      assert result.failure == report

      assert {:error, _report} =
               run([step("solo", %{behavior: :error})], on_progress: on_progress)

      assert %Progress{data: %RunResult{kind: :execution_failed, variant: %{index: 0}}} =
               last_progress()
    end
  end

  describe "persistence" do
    @describetag :tmp_dir

    test "a two-target divergence report round-trips at version 9", %{tmp_dir: dir} do
      {:error, report} = run([step("a"), step("b", %{behavior: :shift})])

      assert {:ok, path} = Persistence.save(report, dir)
      assert {:ok, <<"PD", 9::8, _rest::binary>>} = File.read(path)
      assert {:ok, loaded} = Persistence.load(path)

      assert loaded.kind == :diverged
      assert loaded.variant == report.variant
      assert loaded.targets == report.targets
      assert loaded.failure_reason == report.failure_reason
    end

    test "a version-8 file is refused", %{tmp_dir: dir} do
      {:error, report} = run([step("a"), step("b", %{behavior: :shift})])
      term_binary = :erlang.term_to_binary(%{format_version: 8, report: report})
      path = Path.join(dir, "v8.pd")
      File.write!(path, <<"PD", 8::8, :erlang.crc32(term_binary)::32, term_binary::binary>>)

      assert {:error, {:unsupported_format_version, 8, 9}} = Persistence.load(path)
    end
  end

  describe "compare: :performance" do
    test "on one target returns metrics for its variant" do
      assert {:ok, stats} = run([step("solo")], compare: :performance, max_runs: 2)

      assert Map.keys(stats.metrics) == ["solo"]
      assert is_number(stats.metrics["solo"].latency_p50)
    end

    test "on two targets under :serial returns metrics keyed by both names" do
      assert {:ok, stats} = run([step("a"), step("b")], compare: :performance, max_runs: 2)

      assert stats.metrics |> Map.keys() |> Enum.sort() == ["a", "b"]
    end
  end

  describe "reproduction_command/1" do
    test "prints both targets with their config and a non-default concurrency" do
      {:error, report} =
        run([step("a"), step("b", %{behavior: :shift})], concurrency: :parallel)

      command = FailureReport.reproduction_command(report)

      adapter = inspect(StepAdapter)
      config_b = inspect(%{name: "b", behavior: :shift})

      assert command =~
               ~s|targets: [{#{adapter}, name: "a", config: %{name: "a"}}, | <>
                 ~s|{#{adapter}, name: "b", config: #{config_b}}]|

      assert command =~ "concurrency: :parallel"
      assert command =~ "seed: #{@seed}"
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp last_progress do
    collect_progress([]) |> List.last()
  end

  defp collect_progress(acc) do
    receive do
      {:progress, progress} -> collect_progress(acc ++ [progress])
    after
      0 -> acc
    end
  end

  # The sink projection sends its state after every command and event to the
  # process registered under the sink name.
  defp with_sink(fun) do
    Process.register(self(), Sink.name())

    try do
      fun.()
    after
      Process.unregister(Sink.name())
    end
  end

  defp take_states do
    receive do
      {:sink_state, state} -> [state | take_states()]
    after
      0 -> []
    end
  end

  defmodule Sink do
    @moduledoc false
    # Folds like Ledger and reports every state it checks to the registered
    # test process.
    use PropertyDamage.Model.Projection

    def name, do: :pd_run_targets_test_sink

    @impl true
    def init, do: Ledger.init()

    @impl true
    def apply(state, event), do: Ledger.apply(state, event)

    @check every: 1
    def assert_reported(state, _command_or_event) do
      if pid = Process.whereis(name()), do: send(pid, {:sink_state, state})
      :ok
    end
  end

  defmodule SinkModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Step]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [PropertyDamage.RunTargetsTest.Sink]
  end
end
