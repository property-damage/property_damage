defmodule PropertyDamage.Test.RunnerSupport do
  @moduledoc false
  # Runs one generated plan the way a campaign runs its first run, through
  # either run driver, and renders what the run did as plain data.
  #
  # `scheduler_run/2` calls the lockstep scheduler with the options a campaign
  # passes for a linear plan. `run_plan/2` hands the same plan and run options
  # to the run driver, `PropertyDamage.Runner`. It is the one place the tests
  # name that module, so a change to the driver's call shape changes this file
  # only. The module is held in a variable, which the compiler does not check,
  # so the file compiles whether or not the driver exists.
  #
  # `inputs` is `%{model:, targets:, sequence:}`; `opts` holds the run options
  # (`:seed` is required).

  alias PropertyDamage.{Expansion, Failure, Generator, Options, Scheduler, Sequence, Stutter}
  alias PropertyDamage.Log.Cap
  alias PropertyDamage.Test.SeedCharacterization, as: S

  @doc "The targets a campaign builds from `targets:` entries."
  def targets(entries), do: Options.override_targets!([], entries)

  @doc """
  The sequence a campaign generates for run `run_number` of `seed`: setup
  commands and roots from the run seed, then the teardown commands generated
  against them.
  """
  def plan_for(model, seed, run_number, max_commands) do
    run_seed = Generator.run_seed(seed, run_number)
    markers = [external_markers: []]

    model
    |> Generator.generate_sequence([max_commands: max_commands] ++ markers)
    |> Generator.generate_value(run_seed)
    |> then(&Generator.teardown_commands(model, &1, run_seed, markers))
  end

  @doc "Runs the plan through the lockstep scheduler; returns its outcome."
  def scheduler_run(inputs, opts) do
    {:ok, outcome} = Scheduler.run(scheduler_options(inputs, run_options(opts)))
    outcome
  end

  @doc "Runs the plan through the run driver; returns its outcome."
  def run_plan(inputs, opts) do
    runner = Module.concat([PropertyDamage, Runner])
    context = struct!(Module.concat(runner, Context), context_fields(inputs, run_options(opts)))

    case runner.execute(plan(inputs), context) do
      {:ok, outcome} -> outcome
      outcome -> outcome
    end
  end

  @doc "The event log of every target's result, rendered as plain data."
  def events(%{results: results}), do: Enum.map(results, &log(&1.event_log))

  @doc "An event log rendered as plain data: source, phase, command index, event."
  def log(entries) do
    Enum.map(entries, &{&1.source, &1.phase, &1.command_index, S.norm(&1.event)})
  end

  @doc "What identifies a run's failure, or nil when the run passed."
  def identity(%{failure: nil}), do: nil

  def identity(%{failure: failure}) do
    {failure.report_kind, Failure.kind(failure.reason), failure.root, failure.variant.index,
     Failure.name(failure.reason)}
  end

  defp plan(%{sequence: sequence, targets: targets}) do
    %{
      commands: Sequence.to_list(sequence),
      variants: Expansion.schedule(targets, Expansion.identity(sequence, targets)),
      setup_commands: sequence.setup,
      teardown_commands: sequence.teardown,
      placeholder_registry: sequence.registry
    }
  end

  # The run options a campaign passes for its first, linear run.
  defp run_options(opts) do
    Keyword.merge(
      [
        run_number: 0,
        run_nonce: 1,
        mint_epoch: 0,
        concurrency: :serial,
        compare: [],
        measure_latency: false,
        stutter_config: Stutter.parse_config(nil),
        keep_attempts: Cap.default_keep_attempts(),
        check_mode: :halt
      ],
      opts
    )
  end

  defp scheduler_options(%{model: model, targets: targets} = inputs, opts) do
    inputs
    |> plan()
    |> Map.to_list()
    |> Keyword.merge(model: model, targets: targets)
    |> Keyword.merge(opts)
  end

  defp context_fields(%{model: model, targets: targets}, opts),
    do: Keyword.merge([model: model, targets: targets], opts)
end
