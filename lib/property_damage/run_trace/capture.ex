defmodule PropertyDamage.RunTrace.Capture do
  @moduledoc """
  Runs one plan through `PropertyDamage.Runner` and records it as a `PropertyDamage.RunTrace` (DR-035).

  Kept apart from `PropertyDamage.RunTrace` so the trace stays a plain record
  that the scheduler, the failure report and persistence can all depend on
  without depending on the engine that fills it.
  """

  alias PropertyDamage.{Expansion, Generator, Options, Runner, RunTrace, Sequence}
  alias PropertyDamage.Runner.Context

  @doc """
  Run ONE full, unshrunk plan and return its trace, pass or fail (DR-035).

  This is the input to `PropertyDamage.RunComparison`. Unlike the exploration
  loop it never shrinks and never stops early on failure: it captures the whole
  execution record of a single run. `plan_source` is always `:generated` (the
  plan is a pure function of the effective seed). The plan carries the setup
  and teardown commands generated as `PropertyDamage.run/1` generates them, and the
  target runs them before and after the roots.

  ## Options

  Required: `:model`, `:targets` (exactly one entry; `mocks:` is not supported),
  `:seed`.

  Optional: `:run_number` (default 0), `:run_nonce` (default fresh crypto
  entropy, DR-034), `:mint_epoch` (default 0),
  `:max_commands` (default 50), `:source_revision` (default
  detected). The target's `injectors:` (fault/async injectors) are set up around
  the run so their events land in the trace.

  For a model with `c:PropertyDamage.Model.expansions/0`, the target chooses
  at each root by its `expansion:` option exactly as `PropertyDamage.run/1`
  does for the same seed, run number and target name, runs the leaves it
  chose through `PropertyDamage.Runner`, as a run does, and the trace records
  what it ran in `expansion`. Every model runs through the runner, so a
  trace's step events are the events of the run it explains, the boundary
  drain after each root included.
  """
  @spec capture(keyword()) :: RunTrace.t()
  def capture(opts) do
    model = Keyword.fetch!(opts, :model)
    target = Options.required_target!(opts)

    Options.reject_unsupported_target_keys!(
      [target],
      [:mocks],
      "PropertyDamage.RunTrace.Capture.capture/1"
    )

    seed = Keyword.fetch!(opts, :seed)
    run_number = Keyword.get(opts, :run_number, 0)

    run_nonce =
      Keyword.get(opts, :run_nonce) ||
        :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()

    mint_epoch = Keyword.get(opts, :mint_epoch, 0)
    max_commands = Keyword.get(opts, :max_commands, 50)

    run_seed = Generator.run_seed(seed, run_number)

    # The plan as `PropertyDamage.run/1` generates it: the setup commands and
    # the roots, then the teardown commands generated against them.
    plan =
      model
      |> Generator.generate_sequence(max_commands: max_commands)
      |> Generator.generate_value(run_seed)
      |> then(&Generator.teardown_commands(model, &1, run_seed))

    # A model with expansions: the target's concrete sequence, as a run draws
    # it for this seed and target name. Any other model runs its roots as
    # themselves.
    {expansion, recorded} =
      if Expansion.defines?(model) do
        expansion = Expansion.expand(model, plan, [target], run_seed)
        {expansion, %{target.name => expansion.variants[target.name].choices}}
      else
        {Expansion.identity(plan, [target]), nil}
      end

    context = %Context{
      model: model,
      targets: [target],
      seed: seed,
      run_number: run_number,
      run_nonce: run_nonce,
      mint_epoch: mint_epoch,
      concurrency: :serial
    }

    {:ok, outcome} =
      Runner.execute(
        %{
          commands: Sequence.to_list(plan),
          variants: Expansion.schedule([target], expansion),
          setup_commands: plan.setup,
          teardown_commands: plan.teardown,
          placeholder_registry: plan.registry
        },
        context
      )

    RunTrace.new(
      [
        seed: seed,
        run_number: run_number,
        run_nonce: run_nonce,
        mint_epoch: mint_epoch,
        model: model,
        adapter: target.adapter,
        source_revision: Keyword.get_lazy(opts, :source_revision, &RunTrace.source_revision/0),
        plan: plan,
        plan_source: :generated,
        command_labels: %{},
        expansion: recorded
      ] ++ recorded_run(outcome)
    )
  end

  # What the run did, from its single target's result. A run whose target
  # could not be set up has no result: nothing ran, and the trace says so
  # instead of raising.
  defp recorded_run(%{results: [%{} = result]}) do
    [
      executed: Map.get(result, :executed, %{}),
      event_log: result.event_log,
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      outcome: outcome_of(result)
    ]
  end

  defp recorded_run(%{results: [], failure: %{reason: reason}}), do: [outcome: {:fail, reason}]

  defp outcome_of(%{success: true}), do: :pass
  defp outcome_of(%{failure_reason: reason}), do: {:fail, reason}
end
