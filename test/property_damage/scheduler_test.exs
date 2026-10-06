defmodule PropertyDamage.SchedulerTest do
  # One run over N variants in lockstep: every variant reaches boundary r, the
  # comparison runs, then boundary r + 1. With one variant the run equals the
  # linear engine's run of the same sequence.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{EventQueue, Failure, Generator}
  alias PropertyDamage.Test.VariantSupport.Barrier

  alias PropertyDamage.Test.Lockstep.{
    GuardedStepModel,
    Ledger,
    Noted,
    NoteInjector,
    Polled,
    StartupModel,
    Step,
    StepAdapter,
    StepModel
  }

  @seed 4242
  @run_number 2
  @run_nonce 42

  defp run_opts(model, targets, commands, extra) do
    Keyword.merge(
      [
        model: model,
        targets: targets,
        commands: commands,
        seed: @seed,
        run_number: @run_number,
        run_nonce: @run_nonce,
        concurrency: :serial,
        compare: :correctness,
        equivalence: :exact
      ],
      extra
    )
  end

  defp step_targets(names, config) do
    targets!(
      for name <- names do
        {StepAdapter, name: name, config: Map.merge(%{name: name}, config)}
      end
    )
  end

  defp calls(recorder) do
    for {tag, _name, _index} = entry <- recorded(recorder), tag in [:enter, :exit], do: entry
  end

  defp entered(recorder, name) do
    for {:enter, ^name, index} <- recorded(recorder), do: index
  end

  describe "concurrency: :serial" do
    test "advances one variant at a time, in target order, boundary by boundary" do
      recorder = start_recorder()
      targets = step_targets(["a", "b"], %{recorder: recorder, hold_ms: 20})
      commands = for value <- 1..3, do: %Step{value: value}

      assert {:ok, run} = run_scheduler(run_opts(StepModel, targets, commands, []))
      assert run.failure == nil

      assert calls(recorder) ==
               Enum.flat_map(0..2, fn index ->
                 [
                   {:enter, "a", index},
                   {:exit, "a", index},
                   {:enter, "b", index},
                   {:exit, "b", index}
                 ]
               end)
    end
  end

  describe "concurrency: :parallel" do
    test "steps of one boundary overlap, no variant starts r + 1 early, and pollers stay with their variant" do
      recorder = start_recorder()
      {:ok, barrier} = Barrier.start_link(2)

      targets =
        targets!([
          {StepAdapter,
           name: "a", config: %{name: "a", recorder: recorder, barrier: barrier, hold_ms: 10}},
          {StepAdapter,
           name: "b",
           config: %{name: "b", recorder: recorder, barrier: barrier, hold_ms: 10, poll: :deliver}}
        ])

      commands = for value <- 1..3, do: %Step{value: value}

      assert {:ok, run} =
               run_scheduler(run_opts(StepModel, targets, commands, concurrency: :parallel))

      assert run.failure == nil

      log = recorded(recorder)

      # Both variants were inside the same command at once, at every boundary.
      barrier_results = for {:barrier, _name, index, result} <- log, do: {index, result}
      assert Enum.sort(barrier_results) == for(i <- 0..2, _ <- 1..2, do: {i, :all})

      # Every variant left command r before any variant entered command r + 1.
      for index <- 1..2 do
        previous = index - 1
        last_exit = last_position(log, &match?({:exit, _, ^previous}, &1))
        first_enter = first_position(log, &match?({:enter, _, ^index}, &1))
        assert last_exit < first_enter
      end

      # Only the variant whose adapter started resource pollers folded their events.
      [result_a, result_b] = run.results
      assert events_from(result_a.event_log, :resource_poller) == []

      polled_ids =
        for %Polled{id: id} <- events_from(result_b.event_log, :resource_poller), do: id

      assert Enum.sort(polled_ids) == [1, 2, 3]
    end
  end

  describe "a one-variant run equals the linear engine's run" do
    test "on a passing sequence" do
      commands = for value <- [1, 2, 3], do: %Step{value: value}
      {oracle, oracle_recorder} = linear_run(GuardedStepModel, commands, %{})

      recorder = start_recorder()
      targets = step_targets(["solo"], %{recorder: recorder})

      assert {:ok, run} = run_scheduler(run_opts(GuardedStepModel, targets, commands, []))
      assert run.failure == nil
      assert [result] = run.results

      assert recorded(recorder) == recorded(oracle_recorder)
      assert oracle.success
      assert result.success
      assert result.projections == oracle.projections
      assert entries(result.event_log) == entries(oracle.event_log)
    end

    test "on a planted check failure" do
      commands = for value <- [1, 13, 3], do: %Step{value: value}
      {oracle, oracle_recorder} = linear_run(GuardedStepModel, commands, %{})

      recorder = start_recorder()
      targets = step_targets(["solo"], %{recorder: recorder})

      assert {:ok, run} = run_scheduler(run_opts(GuardedStepModel, targets, commands, []))
      assert [result] = run.results

      assert recorded(recorder) == recorded(oracle_recorder)
      refute oracle.success
      assert oracle.failed_at_index == 1
      assert result.success == oracle.success
      assert result.failed_at_index == oracle.failed_at_index
      assert result.failure_reason == oracle.failure_reason
      assert result.projections == oracle.projections
      assert entries(result.event_log) == entries(oracle.event_log)

      assert %{kind: :check_failed, variant: %{index: 0, name: "solo"}, root: 1} = run.failure
      assert run.failure.run == @run_number

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} =
               run.failure.reason
    end

    test "on a failing :startup check, which runs after setup and before command 0" do
      commands = [%Step{value: 1}]
      {oracle, oracle_recorder} = linear_run(StartupModel, commands, %{fail_startup: true})
      Process.delete(:lockstep_fail_startup)

      recorder = start_recorder()
      targets = step_targets(["solo"], %{recorder: recorder, fail_startup: true})

      assert {:ok, run} = run_scheduler(run_opts(StartupModel, targets, commands, []))
      assert [result] = run.results

      assert recorded(recorder) == recorded(oracle_recorder)
      assert entered(recorder, "solo") == []
      refute oracle.success
      assert oracle.failed_at_index == nil
      assert result.success == oracle.success
      assert result.failed_at_index == oracle.failed_at_index
      assert result.failure_reason == oracle.failure_reason

      assert %{kind: :check_failed, variant: %{index: 0, name: "solo"}, root: nil} = run.failure
    end
  end

  describe "adapter {:error, _} at a root" do
    test "with two variants it is compared like any observation and both variants continue" do
      recorder = start_recorder()
      targets = step_targets(["a", "b"], %{recorder: recorder})
      commands = [%Step{value: 1}, %Step{value: 2, fail: true}, %Step{value: 3}]

      assert {:ok, run} = run_scheduler(run_opts(StepModel, targets, commands, []))
      assert run.failure == nil
      assert entered(recorder, "a") == [0, 1, 2]
      assert entered(recorder, "b") == [0, 1, 2]
    end

    test "with one variant it ends the run as the linear engine does" do
      commands = [%Step{value: 1}, %Step{value: 2, fail: true}, %Step{value: 3}]
      {oracle, oracle_recorder} = linear_run(StepModel, commands, %{})

      recorder = start_recorder()
      targets = step_targets(["solo"], %{recorder: recorder})

      assert {:ok, run} = run_scheduler(run_opts(StepModel, targets, commands, []))
      refute match?(%{kind: :diverged}, run.failure)
      assert [result] = run.results

      assert entered(recorder, "solo") == [0, 1]
      assert recorded(recorder) == recorded(oracle_recorder)
      refute result.success
      assert result.failed_at_index == oracle.failed_at_index
      assert result.failed_at_index == 1
      assert result.failure_reason == oracle.failure_reason

      assert %Failure{type: %Failure.Execution{kind: :adapter_error, detail: :refused}} =
               result.failure_reason
    end
  end

  describe "per-target injectors" do
    test "an injector declared on variant 1 delivers its events to variant 1 only" do
      targets =
        targets!([
          {StepAdapter, name: "a", config: %{name: "a"}},
          {StepAdapter, name: "b", config: %{name: "b"}, injectors: [NoteInjector]}
        ])

      commands = [%Step{value: 1}, %Step{value: 2}]

      assert {:ok, run} = run_scheduler(run_opts(StepModel, targets, commands, []))
      refute match?(%{kind: :diverged}, run.failure)
      assert [result_a, result_b] = run.results

      assert events_from(result_a.event_log, :injector) == []
      assert result_a.projections[Ledger].noted == []
      assert events_from(result_b.event_log, :injector) == [%Noted{value: :from_injector}]
      assert result_b.projections[Ledger].noted == [:from_injector]
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # The linear engine's run of `commands` with the per-run options a
  # one-variant run uses, and the recorder its adapter wrote to.
  defp linear_run(model, commands, config) do
    recorder = start_recorder()
    {:ok, queue} = EventQueue.start_link()

    result =
      executor_run(commands, model, StepAdapter,
        config: Map.merge(%{name: "solo", recorder: recorder}, config),
        event_queue: queue,
        rng_seed: Generator.run_seed(@seed, @run_number),
        run_nonce: @run_nonce,
        mint_epoch: 0
      )

    EventQueue.stop(queue)
    {result, recorder}
  end

  defp first_position(log, fun), do: Enum.find_index(log, fun)

  defp last_position(log, fun) do
    length(log) - 1 - Enum.find_index(Enum.reverse(log), fun)
  end
end
