defmodule PropertyDamage.RunTrace.Capture do
  @moduledoc """
  Runs one plan and records it as a `PropertyDamage.RunTrace` (DR-035).

  Kept apart from `PropertyDamage.RunTrace` so the trace stays a plain record
  that the scheduler, the failure report and persistence can all depend on
  without depending on the engine that fills it.
  """

  alias PropertyDamage.{Executor, Expansion, Failure, Generator, Options}
  alias PropertyDamage.Runtime.RunServices
  alias PropertyDamage.{RunTrace, Scheduler, Sequence}

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
  chose through the same engine path a run's target uses
  (`PropertyDamage.Scheduler`, one target), and the trace records what it ran
  in `expansion`.
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

    if Expansion.defines?(model) do
      capture_expanded(opts, model, target, plan, %{
        seed: seed,
        run_number: run_number,
        run_seed: run_seed,
        run_nonce: run_nonce,
        mint_epoch: mint_epoch
      })
    else
      capture_engine(opts, model, target, plan, %{
        seed: seed,
        run_number: run_number,
        run_seed: run_seed,
        run_nonce: run_nonce,
        mint_epoch: mint_epoch
      })
    end
  end

  defp capture_engine(opts, model, target, plan, run) do
    %{adapter: adapter, config: config} = target
    %{seed: seed, run_number: run_number, run_seed: run_seed} = run
    %{run_nonce: run_nonce, mint_epoch: mint_epoch} = run

    # The target's injectors are set up against the run's event queue, as on
    # every other path that executes a run. `mocks:` is rejected above.
    run_result =
      RunServices.with_services(target, fn event_queue, _mock_registry ->
        Executor.run(plan, model, adapter,
          config: config,
          event_queue: event_queue,
          rng_seed: run_seed,
          run_nonce: run_nonce,
          mint_epoch: mint_epoch,
          setup_commands: plan.setup,
          teardown_commands: plan.teardown
        )
      end)

    captured =
      case run_result do
        {:ok, result} ->
          [
            executed: Map.get(result, :executed, %{}),
            event_log: result.event_log,
            command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
            outcome: outcome_of(result)
          ]

        # An injector's or the adapter's setup failed: nothing ran, and the
        # trace says so instead of raising, as the scheduler path does.
        {:error, reason} ->
          [outcome: {:fail, Failure.setup_failed(reason)}]
      end

    RunTrace.new(
      [
        seed: seed,
        run_number: run_number,
        run_nonce: run_nonce,
        mint_epoch: mint_epoch,
        model: model,
        adapter: adapter,
        source_revision: Keyword.get_lazy(opts, :source_revision, &RunTrace.source_revision/0),
        plan: plan,
        plan_source: :generated,
        command_labels: %{}
      ] ++ captured
    )
  end

  # A model with expansions: the target's concrete sequence, as a run draws it
  # for this seed and target name, runs through the scheduler with that one
  # target, which sets up its event queue and injectors.
  defp capture_expanded(opts, model, target, plan, run) do
    expansion = Expansion.expand(model, plan, [target], run.run_seed)

    {:ok, outcome} =
      Scheduler.run(
        model: model,
        targets: [target],
        commands: Sequence.to_list(plan),
        variants: Expansion.schedule([target], expansion),
        setup_commands: plan.setup,
        teardown_commands: plan.teardown,
        placeholder_registry: plan.registry,
        seed: run.seed,
        run_number: run.run_number,
        run_nonce: run.run_nonce,
        mint_epoch: run.mint_epoch,
        concurrency: :serial
      )

    [%{} = result] = outcome.results

    RunTrace.new(
      seed: run.seed,
      run_number: run.run_number,
      run_nonce: run.run_nonce,
      mint_epoch: run.mint_epoch,
      model: model,
      adapter: target.adapter,
      source_revision: Keyword.get_lazy(opts, :source_revision, &RunTrace.source_revision/0),
      plan: plan,
      plan_source: :generated,
      executed: Map.get(result, :executed, %{}),
      event_log: result.event_log,
      command_labels: %{},
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      expansion: %{target.name => expansion.variants[target.name].choices},
      outcome: outcome_of(result)
    )
  end

  defp outcome_of(%{success: true}), do: :pass
  defp outcome_of(%{failure_reason: reason}), do: {:fail, reason}
end
