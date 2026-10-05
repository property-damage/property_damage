defmodule PropertyDamage.Scheduler do
  @moduledoc """
  Runs one command sequence against several targets in lockstep and compares
  their answers command by command.

  Each target runs as a `PropertyDamage.Variant`: its own process with its own
  executor state, event queue, injectors, mocks and pollers. The scheduler only
  tells the variants how far to go and looks at what they observed.
  `PropertyDamage.run/1` calls `run/1` once per generated linear sequence, for
  one target or several.

  ## Lockstep

  Every command of the sequence is a root. For each root `r`, in order, every
  variant executes command `r` and stops at boundary `r`; only then does the
  comparison run, and only after it does any variant start command `r + 1`.
  Two settings decide how the variants reach a boundary:

    * `concurrency: :serial` - one variant at a time, in target order. Commands
      never overlap, so targets that share one system do not disturb each
      other, and per-command latency is measured without other load.
    * `concurrency: :parallel` - every variant executes command `r` at the same
      time. The run takes about as long as its slowest target, but the targets'
      commands overlap: targets that share a system need isolated slices of it
      (a tenant or a key prefix per target, through each target's `config:`),
      or one target's command changes what another observes.

  ## Per-run setup and the barrier

  The variants are set up one after another in target order: each variant
  calls its adapter's `setup/1` in its own process, and the next setup starts
  after the previous one returned. No variant executes command 0 before every
  setup returned and every `@check at: :startup` check passed. At the end of
  the run, pass or fail, every variant that was set up finalizes its run and
  tears its adapter down, again in its own process.

  So `c:PropertyDamage.Adapter.setup/1` runs once per run per target, and may
  find state a previous run (or a crashed one) left behind: it must be
  idempotent.

  ## Observation and comparison

  A variant observes each root as `{:ok, events}` (the events the command
  injected, then the events it returned; for a `:probe` or `:async` command,
  the settled events) or `{:error, reason}` (the adapter's error answer). The
  first target is the reference. At each boundary, each other target's
  observation is compared with the reference's under the run's equivalence
  strategy (`:exact`, `:structural` or a 2-arity function); the first target (in target order)
  that is not equivalent is the run's divergence, a failure of kind `:diverged`,
  and the run stops at that boundary. One function holds this comparison, so the observation compared at
  a boundary can be changed in one place. With one target there is no
  comparison, and an adapter `{:error, _}` ends the run as it does in
  `PropertyDamage.run/1`; with two or more it is an observation like any other.

  ## Failures

  A failure ends the run and names the target it happened in. Its `reason` is
  always a `%PropertyDamage.Failure{}`:

    * `:diverged` - a target answered a root differently from the reference
      (`PropertyDamage.Failure.diverged/5`). Its name is the root command's
      module, so a divergence at a command of another type is another failure.
    * `:setup_failed` - a target's `setup/1` returned an error or raised
      (`PropertyDamage.Failure.setup_failed/1`, holding the error term or the
      exception). Targets already set up are torn down; the failing one is not.
    * `:check_failed` - a check failed in a target: at a command, at the
      `:startup` phase, or while the run finalized (an `@eventually` timeout,
      a `:teardown` check).
    * `:execution_failed` - a target's adapter raised, a command could not be
      executed (the failure the target's engine reported for it), the
      machinery failed while the run finalized (a resource poller error, a
      poll predicate that raised), or the target's process crashed
      (`PropertyDamage.Failure.unknown/1` holding the exit reason).

  A failure's kind is derived from its `reason` by
  `PropertyDamage.FailureReport.kind_of/1`, so a report's `kind` always agrees
  with its `failure_reason`.

  Under `:serial` no other target executes the failing root after the failure;
  under `:parallel` the commands already running finish. In both, no target
  starts the next root.
  """

  alias PropertyDamage.{Comparison, Failure, FailureReport, PlaceholderRegistry, Target, Variant}

  @typedoc "A target's position in `targets:` and its name."
  @type variant :: %{index: non_neg_integer(), name: String.t()}

  @typedoc """
  What ended a run, naming the target it happened in. `root` is the command the
  failure belongs to, `nil` for a setup failure or a failed `:startup` check.
  """
  @type failure :: %{
          kind: :check_failed | :setup_failed | :execution_failed | :diverged,
          variant: variant(),
          run: non_neg_integer(),
          root: non_neg_integer() | nil,
          reason: Failure.t()
        }

  @typedoc """
  The outcome of one run. `results`, `observations` and `latencies` hold one
  entry per target in target order, for every target that was set up (all of
  them unless setup failed, then none). Each result is what
  `PropertyDamage.Executor.run/4` reports for that target's run.
  """
  @type run :: %{
          failure: failure() | nil,
          results: [map()],
          observations: [[{non_neg_integer(), Variant.observation()}]],
          latencies: [[{non_neg_integer(), non_neg_integer()}]]
        }

  # The boundary before command 0: asking a variant to advance to it steps
  # nothing and reports a failed `:startup` check.
  @before_first_root -1

  @doc """
  Run `commands` against every target in lockstep.

  Options (all required unless noted):

    * `:model` - the model module
    * `:targets` - `[%PropertyDamage.Target{}]`; the first is the reference
    * `:commands` - the concrete command list
    * `:seed`, `:run_number` - the campaign seed and the 0-based run
    * `:run_nonce` - the run nonce shared by every target
    * `:concurrency` - `:serial` or `:parallel` (see the module doc)
    * `:compare` - `:correctness`, `:performance` or `:both`; targets are
      compared only under `:correctness` and `:both`
    * `:equivalence` - `:exact`, `:structural` or a 2-arity function
    * `:measure_latency` - record the wall-clock time of each target's `execute/3` per command
      into `latencies` (optional, default `false`)
    * `:mint_epoch` - the mint epoch every target's run uses for client-minted
      values (DR-034); optional, default `0`, the exploration run's epoch
    * `:stutter_config`, `:check_mode` - passed to every variant (optional)
    * `:placeholder_registry` - the registry the commands' placeholders resolve
      against (DR-021); optional, default the registry built from `:commands`.
      A shrunk sequence passes its own registry, whose producer positions were
      remapped onto the shrunk command list.

  Returns `{:ok, run}`; see `t:run/0`.
  """
  @spec run(keyword()) :: {:ok, run()}
  def run(opts) do
    config = build_config(opts)

    case set_up(config) do
      {:ok, variants} ->
        {:ok, finish_run(config, lockstep(config, variants))}

      {:error, failure} ->
        {:ok, empty_run(failure)}
    end
  end

  defp build_config(opts) do
    targets = Keyword.fetch!(opts, :targets)
    commands = Keyword.fetch!(opts, :commands)

    %{
      model: Keyword.fetch!(opts, :model),
      targets: targets,
      commands: commands,
      seed: Keyword.fetch!(opts, :seed),
      run_number: Keyword.fetch!(opts, :run_number),
      run_nonce: Keyword.get(opts, :run_nonce),
      concurrency: Keyword.fetch!(opts, :concurrency),
      compare?: Keyword.fetch!(opts, :compare) in [:correctness, :both] and length(targets) > 1,
      equivalence: Keyword.fetch!(opts, :equivalence),
      measure_latency: Keyword.get(opts, :measure_latency, false),
      mint_epoch: Keyword.get(opts, :mint_epoch, 0),
      stutter_config: Keyword.get(opts, :stutter_config),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      on_adapter_error: if(length(targets) > 1, do: :continue, else: :halt),
      registry: Keyword.get(opts, :placeholder_registry) || PlaceholderRegistry.build(commands)
    }
  end

  defp empty_run(failure) do
    %{failure: failure, results: [], observations: [], latencies: []}
  end

  # ==========================================================================
  # Setup
  # ==========================================================================

  # Starts and sets up one variant after another. On a failure, the variants
  # already set up are stopped (their adapters torn down) and the failing one is
  # stopped without an adapter teardown.
  defp set_up(config) do
    config.targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, ready} ->
      case set_up_variant(config, target) do
        {:ok, variant} ->
          {:cont, {:ok, [variant | ready]}}

        {:error, reason} ->
          Enum.each(ready, &stop_variant/1)
          reason = Failure.setup_failed(reason)
          {:halt, {:error, failure(config, target, nil, reason)}}
      end
    end)
    |> case do
      {:ok, ready} -> {:ok, Enum.reverse(ready)}
      error -> error
    end
  end

  defp set_up_variant(config, target) do
    {:ok, pid} =
      Variant.start(
        target: target,
        model: config.model,
        commands: config.commands,
        placeholder_registry: config.registry,
        seed: config.seed,
        run_number: config.run_number,
        run_nonce: config.run_nonce,
        stutter_config: config.stutter_config,
        check_mode: config.check_mode,
        on_adapter_error: config.on_adapter_error,
        measure_latency: config.measure_latency,
        mint_epoch: config.mint_epoch
      )

    variant = %{pid: pid, target: target, observations: []}

    case call(pid, &Variant.setup/1) do
      {:ok, :ok} ->
        {:ok, variant}

      {:ok, {:error, reason}} ->
        stop_variant(variant)
        {:error, setup_reason(reason)}

      {:crashed, reason} ->
        {:error, reason}
    end
  end

  # A setup that raised is reported by the exception itself.
  defp setup_reason({:raised, exception}), do: exception
  defp setup_reason(reason), do: reason

  # ==========================================================================
  # Lockstep
  # ==========================================================================

  # Returns {variants, failure}, the variants carrying what they observed so
  # far; a divergence is the failure of the boundary it was found at.
  defp lockstep(config, variants) do
    # The barrier: every setup returned and every :startup check passed before
    # any variant executes command 0.
    case advance_all(config, variants, @before_first_root) do
      {:ok, variants} -> step_roots(config, variants)
      {:failed, variants, failure} -> {variants, failure}
    end
  end

  defp step_roots(config, variants) do
    config.commands
    |> Enum.with_index()
    |> Enum.reduce_while({variants, nil}, fn {command, root}, {variants, nil} ->
      case advance_all(config, variants, root) do
        {:ok, variants} ->
          case compare_boundary(config, variants, root, command) do
            nil -> {:cont, {variants, nil}}
            divergence -> {:halt, {variants, divergence}}
          end

        {:failed, variants, failure} ->
          {:halt, {variants, failure}}
      end
    end)
  end

  defp advance_all(%{concurrency: :serial} = config, variants, root) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, advanced} ->
      case advance(config, variant, root) do
        {:ok, variant} ->
          {:cont, {:ok, [variant | advanced]}}

        {:failed, variant, failure} ->
          rest = Enum.drop(variants, length(advanced) + 1)
          {:halt, {:failed, Enum.reverse(advanced, [variant | rest]), failure}}
      end
    end)
    |> case do
      {:ok, advanced} -> {:ok, Enum.reverse(advanced)}
      failed -> failed
    end
  end

  # Every variant steps the root at once; the boundary is reached when every
  # one of them returned. The first failure in target order is the run's.
  defp advance_all(%{concurrency: :parallel} = config, variants, root) do
    advanced =
      variants
      |> Enum.map(fn variant -> Task.async(fn -> advance(config, variant, root) end) end)
      |> Task.await_many(:infinity)

    variants = Enum.map(advanced, &elem(&1, 1))

    case Enum.find(advanced, &match?({:failed, _, _}, &1)) do
      nil -> {:ok, variants}
      {:failed, _variant, failure} -> {:failed, variants, failure}
    end
  end

  defp advance(config, variant, root) do
    case call(variant.pid, &Variant.advance_to(&1, root)) do
      {:ok, {:ok, observed}} ->
        {:ok, %{variant | observations: Enum.reverse(observed, variant.observations)}}

      {:ok, {:failed, %{root: failed_root, reason: reason}}} ->
        {:failed, variant, failure(config, variant.target, failed_root, reason)}

      {:ok, {:error, reason}} ->
        {:failed, variant, failure(config, variant.target, root, reason)}

      {:crashed, reason} ->
        variant = %{variant | pid: nil}
        reason = Failure.unknown(reason)
        {:failed, variant, failure(config, variant.target, root(root), reason)}
    end
  end

  defp root(@before_first_root), do: nil
  defp root(root), do: root

  # ==========================================================================
  # Comparison
  # ==========================================================================

  # The one place a boundary is compared: each non-reference variant's
  # observation of `root` (the index of `command`) against the reference's.
  # Returns the `:diverged` failure of the first non-equivalent variant, or nil.
  defp compare_boundary(%{compare?: false}, _variants, _root, _command), do: nil

  defp compare_boundary(config, variants, root, command) do
    observed = Enum.map(variants, &{&1.target, observation_at(&1, root)})
    [{_reference, reference_result} | others] = observed

    case Enum.find(others, fn {_target, result} ->
           not Comparison.equivalent?(reference_result, result, config.equivalence)
         end) do
      nil ->
        nil

      {target, divergent_result} ->
        results = Map.new(observed, fn {target, result} -> {target.name, result} end)
        reason = Failure.diverged(root, command, reference_result, divergent_result, results)
        failure(config, target, root, reason)
    end
  end

  # Observations are kept newest first, so the latest root is at the head.
  defp observation_at(%{observations: [{root, observation} | _]}, root), do: observation

  # ==========================================================================
  # End of run
  # ==========================================================================

  defp finish_run(config, {variants, failure}) do
    {results, latencies, failure} =
      Enum.reduce(variants, {[], [], failure}, fn variant, {results, latencies, failure} ->
        {result, latency, failure} = finish_variant(config, variant, failure)
        {[result | results], [latency | latencies], failure}
      end)

    results = Enum.reverse(results)

    %{
      failure: with_failure_reason(failure, results),
      results: results,
      observations: Enum.map(variants, &Enum.reverse(&1.observations)),
      latencies: Enum.reverse(latencies)
    }
  end

  # Finalizes and stops one variant. A finalize-time failure (an @eventually
  # timeout, a :teardown check) becomes the run's failure when it has none.
  defp finish_variant(_config, %{pid: nil}, failure), do: {nil, [], failure}

  defp finish_variant(config, variant, failure) do
    latency = latencies(config, variant)

    case call(variant.pid, &Variant.finish/1) do
      {:ok, result} ->
        stop_variant(variant)
        {result, latency, run_failure(config, variant.target, result, failure)}

      {:crashed, reason} ->
        crash = failure(config, variant.target, nil, Failure.unknown(reason))
        {nil, latency, failure || crash}
    end
  end

  # Under `check_mode: :record` a failing check does not end the run: the
  # result carries no failure_reason, only the recorded check failures
  # (chronological). The first of them is the run's failure.
  defp finalize_failure(
         config,
         target,
         %{success: false, failure_reason: nil, check_failures: [first | _]}
       ) do
    reason = Failure.check_failed(first.check_name, without_stacktrace(first.reason))
    failure(config, target, first.command_index, reason)
  end

  defp finalize_failure(config, target, %{success: false} = result) do
    failure(config, target, result.failed_at_index, result.failure_reason)
  end

  defp finalize_failure(_config, _target, _result), do: nil

  # The run's failure after one more variant finished. A finalize-time failure
  # counts when the run has none. Under `check_mode: :record` a check failure
  # the variant recorded at or before the root a divergence was found at
  # happened first: the check failed while that root was stepped, before the
  # boundary was compared.
  defp run_failure(config, target, result, nil), do: finalize_failure(config, target, result)

  defp run_failure(config, target, result, %{kind: :diverged, root: root} = divergence) do
    case result do
      %{success: false, failure_reason: nil, check_failures: [_ | _]} ->
        case finalize_failure(config, target, result) do
          %{root: failed_root} = recorded when is_integer(failed_root) and failed_root <= root ->
            recorded

          _ ->
            divergence
        end

      _ ->
        divergence
    end
  end

  defp run_failure(_config, _target, _result, failure), do: failure

  # A variant reports an adapter raise by the exception alone; the failing
  # variant's finished result holds the `%Failure{}` the engine built for it
  # (the exception with its stacktrace), and the run reports that one.
  defp with_failure_reason(%{reason: %Failure{}} = failure, _results), do: failure
  defp with_failure_reason(nil, _results), do: nil

  defp with_failure_reason(failure, results) do
    reason =
      case Enum.at(results, failure.variant.index) do
        %{failure_reason: %Failure{} = reason} -> reason
        _ -> Failure.adapter_error(failure.reason)
      end

    %{failure | kind: FailureReport.kind_of(reason), reason: reason}
  end

  # A recorded check that raised keeps `{exception, stacktrace}`; a halting run
  # reports the exception alone, and so does this.
  defp without_stacktrace({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace),
       do: exception

  defp without_stacktrace(reason), do: reason

  defp latencies(%{measure_latency: false}, _variant), do: []

  defp latencies(_config, variant) do
    case call(variant.pid, &Variant.latencies/1) do
      {:ok, latencies} -> latencies
      {:crashed, _reason} -> []
    end
  end

  defp stop_variant(%{pid: nil}), do: :ok

  defp stop_variant(variant) do
    call(variant.pid, &Variant.stop/1)
    :ok
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # Calls into a variant. The variant is not linked to the scheduler, so its
  # crash surfaces here as an exit from the call, never as an exit signal.
  defp call(pid, fun) do
    {:ok, fun.(pid)}
  catch
    :exit, reason -> {:crashed, exit_reason(reason)}
  end

  defp exit_reason({{%{__exception__: true} = exception, _stacktrace}, _call}), do: exception
  defp exit_reason({reason, {GenServer, :call, _args}}), do: {:exit, reason}
  defp exit_reason(reason), do: {:exit, reason}

  # Every failure's kind comes from its reason by the one mapping a report
  # uses (`FailureReport.kind_of/1`), so the two always agree. A variant
  # reports an adapter raise by the bare exception; `with_failure_reason/2`
  # swaps in the engine's `%Failure{}` for it and derives the kind again.
  defp failure(config, %Target{} = target, root, reason) do
    %{
      kind: FailureReport.kind_of(reason) || :execution_failed,
      variant: variant_of(target),
      run: config.run_number,
      root: root,
      reason: reason
    }
  end

  defp variant_of(%Target{index: index, name: name}), do: %{index: index, name: name}
end
