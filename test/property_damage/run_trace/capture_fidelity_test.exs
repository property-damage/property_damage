defmodule PropertyDamage.RunTrace.CaptureFidelityTest do
  @moduledoc """
  A trace explains a run, so its event log must be the log the run produced.

  The fixture charges the account once after every command step, from outside
  the command (see `PropertyDamage.Test.BoundaryDrain`). A campaign run folds
  each charge at the root boundary that follows its command; running the plan
  command by command without that fold puts the charge after the next
  command's own events. The controls show the two orders differ and that the
  fixture is quiet when nothing arrives asynchronously.
  """
  # The fixture's event box is one named process.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Executor, Failure, RunTrace}
  alias PropertyDamage.Runtime.RunServices
  alias PropertyDamage.Test.BoundaryDrain, as: Drain
  alias PropertyDamage.Test.RunnerSupport

  @seed 1
  @max_commands 4
  @with_injector [{Drain.Adapter, injectors: [Drain.Injector]}]
  @without_injector [Drain.Adapter]

  setup do
    start_supervised!(%{id: Drain.Box, start: {Drain.Box, :start, []}})
    :ok
  end

  # The trace of the plan, as a campaign target would run it.
  defp traced(model, entries) do
    Drain.Box.reset()

    RunTrace.Capture.capture(
      model: model,
      targets: entries,
      seed: @seed,
      max_commands: @max_commands,
      run_nonce: 1
    )
  end

  # The same plan through the lockstep scheduler, which a campaign calls.
  defp scheduled(model, entries) do
    Drain.Box.reset()
    inputs = inputs(model, entries)
    outcome = RunnerSupport.scheduler_run(inputs, seed: @seed)
    {RunnerSupport.events(outcome) |> hd(), outcome}
  end

  # The same plan through the one-command-at-a-time engine path, with the
  # target's event queue and injectors up around it.
  defp engine_log(model, entries) do
    Drain.Box.reset()
    %{sequence: plan, targets: [target]} = inputs(model, entries)

    {:ok, result} =
      RunServices.with_services(target, fn event_queue, _mocks ->
        Executor.run(plan, model, target.adapter,
          config: target.config,
          event_queue: event_queue,
          rng_seed: PropertyDamage.Generator.run_seed(@seed, 0),
          run_nonce: 1,
          mint_epoch: 0,
          setup_commands: plan.setup,
          teardown_commands: plan.teardown
        )
      end)

    RunnerSupport.log(result.event_log)
  end

  defp inputs(model, entries) do
    %{
      model: model,
      targets: RunnerSupport.targets(entries),
      sequence: RunnerSupport.plan_for(model, @seed, 0, @max_commands)
    }
  end

  describe "the fixture" do
    test "control: the scheduler folds each charge before the next command" do
      {events, outcome} = scheduled(Drain.QuietModel, @with_injector)

      assert outcome.failure == nil

      assert [
               {:command, :root, 0, _spent},
               {:injector, :root, nil, _charged} | [{:command, :root, 1, _next} | _]
             ] = events
    end

    test "control: the engine path folds a charge after the next command, so the logs differ" do
      {boundary, _outcome} = scheduled(Drain.QuietModel, @with_injector)
      engine = engine_log(Drain.QuietModel, @with_injector)

      assert [{:command, :root, 0, _}, {:command, :root, 1, _}, {:injector, :root, nil, _} | _] =
               engine

      refute engine == boundary
      assert length(engine) == length(boundary)
      assert Enum.count(engine, &match?({:injector, _, _, _}, &1)) == @max_commands
    end

    test "control: without an injector nothing arrives and both engine paths agree" do
      {boundary, outcome} = scheduled(Drain.QuietModel, @without_injector)
      engine = engine_log(Drain.QuietModel, @without_injector)

      assert outcome.failure == nil
      assert length(boundary) == @max_commands
      refute Enum.any?(boundary, &match?({:injector, _, _, _}, &1))
      assert engine == boundary

      trace = traced(Drain.QuietModel, @without_injector)
      assert RunnerSupport.log(trace.event_log) == boundary
    end
  end

  describe "RunTrace.Capture.capture/1" do
    test "records the events of the run it explains, boundary folds included" do
      {boundary, _outcome} = scheduled(Drain.QuietModel, @with_injector)
      trace = traced(Drain.QuietModel, @with_injector)

      assert trace.outcome == :pass
      assert RunnerSupport.log(trace.event_log) == boundary
    end

    test "records the events and failure of a failing run as the campaign sees them" do
      {boundary, outcome} = scheduled(Drain.Model, @with_injector)
      trace = traced(Drain.Model, @with_injector)

      assert %{failure: %{root: 2}} = outcome
      assert {:fail, %Failure{} = failure} = trace.outcome
      assert {Failure.kind(failure), Failure.name(failure)} == identity(outcome)
      assert RunnerSupport.log(trace.event_log) == boundary
    end
  end

  defp identity(%{failure: failure}),
    do: {Failure.kind(failure.reason), Failure.name(failure.reason)}
end
