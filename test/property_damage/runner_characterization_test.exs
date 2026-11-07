defmodule PropertyDamage.RunnerCharacterizationTest do
  @moduledoc """
  Pins what the run driver does with the first, linear plan of each seed of
  the seeded-defect models: the same outcome, event logs and failure as the
  lockstep scheduler the campaign calls for that plan, and the same as the
  golden files say about that run.

  A golden file records a whole campaign, so only its parts that follow from
  the first run are read: the generated plans, whether the campaign failed in
  run 0, the failure's kind and check, and (for a passing campaign) the events
  the adapter answered. A failing campaign's `events` come from the shrunk
  reproduction, not from run 0, and stay unread.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence
  alias PropertyDamage.Test.RunnerSupport
  alias PropertyDamage.Test.SeedCharacterization, as: S

  for name <- S.case_names() do
    @case_name name

    describe "#{name}" do
      setup do
        {:ok, golden: S.golden_path(@case_name) |> S.read_golden!() |> Map.new()}
      end

      for seed <- S.seeds(name) do
        @seed seed

        test "scheduler control, seed #{seed}: the first run is the golden run's first run",
             %{golden: golden} do
          assert_golden(
            first_run(&RunnerSupport.scheduler_run/2, @case_name, @seed),
            Map.fetch!(golden, @seed)
          )
        end

        # Unbuilt until the runner exists.
        @tag :known_defect
        test "runner, seed #{seed}: the first run equals the scheduler's and the golden run's",
             %{golden: golden} do
          scheduled = first_run(&RunnerSupport.scheduler_run/2, @case_name, @seed)
          driven = first_run(&RunnerSupport.run_plan/2, @case_name, @seed)

          assert driven.outcome == scheduled.outcome
          assert driven.events == scheduled.events
          assert driven.identity == scheduled.identity
          assert driven.plan == scheduled.plan

          assert_golden(driven, Map.fetch!(golden, @seed))
        end
      end
    end
  end

  # Runs run 0 of the case's campaign for `seed` through `run` and renders it.
  defp first_run(run, name, seed) do
    %{model: model, adapter: adapter, config: config, max_commands: max} = S.setup_for(name)
    {:ok, tape} = Agent.start_link(fn -> [] end)

    targets = RunnerSupport.targets([{adapter, config: Map.put(config, :tape, tape)}])
    sequence = RunnerSupport.plan_for(model, seed, 0, max)

    outcome =
      run.(%{model: model, targets: targets, sequence: sequence}, seed: seed)

    Agent.stop(tape)

    %{
      outcome: if(outcome.failure, do: :fail, else: :pass),
      events: RunnerSupport.events(outcome),
      identity: RunnerSupport.identity(outcome),
      plan: commands(sequence)
    }
  end

  # The generated command sequence rendered as the golden files render it.
  defp commands(%Sequence{} = sequence) do
    sequence
    |> Sequence.to_list()
    |> Enum.map(fn %{__struct__: module} = command ->
      {inspect(module), command |> Map.from_struct() |> S.norm()}
    end)
  end

  # The golden run says: run 0 is the plan it names first; the campaign failed
  # in run 0 exactly when its failing run was the first one; a failure in run
  # 0 has the golden failure's kind and check; a passing campaign answered
  # run 0's events first.
  defp assert_golden(run, golden) do
    assert run.plan == hd(golden.plans)
    failed_in_first_run? = golden.outcome == :fail and length(golden.plans) == 1

    if failed_in_first_run? do
      assert run.outcome == :fail
      assert {_report_kind, kind, _root, _variant, check} = run.identity
      assert kind == golden.failure.kind
      assert S.norm(check) == golden.failure.check
    else
      assert run.outcome == :pass
    end

    if golden.outcome == :pass do
      answered = run.events |> hd() |> Enum.map(&answered/1)
      assert answered == Enum.take(golden.events, length(answered))
    end
  end

  defp answered({source, _phase, _index, {module, fields}}),
    do: {source, module, S.norm(fields)}
end
