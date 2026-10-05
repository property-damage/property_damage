defmodule PropertyDamage.Scheduler do
  @moduledoc """
  Runs one command sequence against several targets in lockstep and compares
  their answers command by command.

  Each target runs as a `PropertyDamage.Variant`: its own process with its own
  executor state, event queue, injectors, mocks and pollers. The scheduler only
  tells the variants how far to go and looks at what they observed.
  `PropertyDamage.Differential.run/1` calls `run/1` once per generated sequence.

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

  So `PropertyDamage.Adapter.setup/1` runs once per run per target, and may
  find state a previous run (or a crashed one) left behind: it must be
  idempotent.

  ## Observation and comparison

  A variant observes each root as `{:ok, events}` (the events the command
  injected, then the events it returned; for a `:probe` or `:async` command,
  the settled events) or `{:error, reason}` (the adapter's error answer). The
  first target is the reference. At each boundary, each other target's
  observation is compared with the reference's through
  `PropertyDamage.Differential.Equivalence`; the first target (in target order)
  that is not equivalent is the run's divergence, and the run stops at that
  boundary. One function holds this comparison, so the observation compared at
  a boundary can be changed in one place. With one target there is no
  comparison, and an adapter `{:error, _}` ends the run as it does in
  `PropertyDamage.run/1`; with two or more it is an observation like any other.

  ## Failures

  A failure ends the run and names the target it happened in:

    * `:setup_failed` - a target's `setup/1` returned an error or raised.
      Targets already set up are torn down; the failing one is not.
    * `:check_failed` - a check failed in a target: at a command, at the
      `:startup` phase, or while the run finalized (an `@eventually` timeout,
      a `:teardown` check).
    * `:execution_failed` - a target's adapter raised, a command could not be
      executed, or the target's process crashed.

  Under `:serial` no other target executes the failing root after the failure;
  under `:parallel` the commands already running finish. In both, no target
  starts the next root.
  """

  alias PropertyDamage.Differential.Equivalence
  alias PropertyDamage.{PlaceholderRegistry, Target, Variant}

  @typedoc "A target's position in `targets:` and its name."
  @type variant :: %{index: non_neg_integer(), name: String.t()}

  @typedoc "What ended a run, naming the target it happened in."
  @type failure :: %{
          kind: :check_failed | :setup_failed | :execution_failed,
          variant: variant(),
          run: non_neg_integer(),
          root: non_neg_integer() | nil,
          reason: term()
        }

  @typedoc "The first root at which a target answered differently from the reference."
  @type divergence :: %{
          seed: integer(),
          run: non_neg_integer(),
          root: non_neg_integer(),
          command: struct(),
          variant: variant(),
          reference_result: Variant.observation(),
          divergent_result: Variant.observation(),
          results: %{String.t() => Variant.observation()}
        }

  @typedoc """
  The outcome of one run. `results`, `observations` and `latencies` hold one
  entry per target in target order, for every target that was set up (all of
  them unless setup failed, then none).
  """
  @type run :: %{
          divergence: divergence() | nil,
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
    * `:stutter_config`, `:check_mode` - passed to every variant (optional)

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
      stutter_config: Keyword.get(opts, :stutter_config),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      on_adapter_error: if(length(targets) > 1, do: :continue, else: :halt),
      registry: PlaceholderRegistry.build(commands)
    }
  end

  defp empty_run(failure) do
    %{divergence: nil, failure: failure, results: [], observations: [], latencies: []}
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
          {:halt, {:error, failure(config, target, :setup_failed, nil, reason)}}
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
        measure_latency: config.measure_latency
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

  # Returns {variants, divergence, failure}, the variants carrying what they
  # observed so far.
  defp lockstep(config, variants) do
    # The barrier: every setup returned and every :startup check passed before
    # any variant executes command 0.
    case advance_all(config, variants, @before_first_root) do
      {:ok, variants} -> step_roots(config, variants)
      {:failed, variants, failure} -> {variants, nil, failure}
    end
  end

  defp step_roots(config, variants) do
    config.commands
    |> Enum.with_index()
    |> Enum.reduce_while({variants, nil, nil}, fn {command, root}, {variants, nil, nil} ->
      case advance_all(config, variants, root) do
        {:ok, variants} ->
          case compare_boundary(config, variants, command, root) do
            nil -> {:cont, {variants, nil, nil}}
            divergence -> {:halt, {variants, divergence, nil}}
          end

        {:failed, variants, failure} ->
          {:halt, {variants, nil, failure}}
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

      {:ok, {:failed, %{kind: kind, root: failed_root, reason: reason}}} ->
        {:failed, variant, failure(config, variant.target, kind, failed_root, reason)}

      {:ok, {:error, reason}} ->
        {:failed, variant, failure(config, variant.target, :execution_failed, root, reason)}

      {:crashed, reason} ->
        variant = %{variant | pid: nil}
        {:failed, variant, failure(config, variant.target, :execution_failed, root(root), reason)}
    end
  end

  defp root(@before_first_root), do: nil
  defp root(root), do: root

  # ==========================================================================
  # Comparison
  # ==========================================================================

  # The one place a boundary is compared: each non-reference variant's
  # observation of `root` against the reference's. Returns the divergence of
  # the first non-equivalent variant, or nil.
  defp compare_boundary(%{compare?: false}, _variants, _command, _root), do: nil

  defp compare_boundary(config, variants, command, root) do
    observed = Enum.map(variants, &{&1.target, observation_at(&1, root)})
    [{_reference, reference_result} | others] = observed

    case Enum.find(others, fn {_target, result} ->
           not Equivalence.equivalent?(reference_result, result, config.equivalence)
         end) do
      nil ->
        nil

      {target, divergent_result} ->
        %{
          seed: config.seed,
          run: config.run_number,
          root: root,
          command: command,
          variant: variant_of(target),
          reference_result: reference_result,
          divergent_result: divergent_result,
          results: Map.new(observed, fn {target, result} -> {target.name, result} end)
        }
    end
  end

  # Observations are kept newest first, so the latest root is at the head.
  defp observation_at(%{observations: [{root, observation} | _]}, root), do: observation

  # ==========================================================================
  # End of run
  # ==========================================================================

  defp finish_run(config, {variants, divergence, failure}) do
    {results, latencies, failure} =
      Enum.reduce(variants, {[], [], failure}, fn variant, {results, latencies, failure} ->
        {result, latency, failure} = finish_variant(config, variant, failure)
        {[result | results], [latency | latencies], failure}
      end)

    %{
      divergence: divergence,
      failure: failure,
      results: Enum.reverse(results),
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
        {result, latency, failure || finalize_failure(config, variant.target, result)}

      {:crashed, reason} ->
        crash = failure(config, variant.target, :execution_failed, nil, reason)
        {nil, latency, failure || crash}
    end
  end

  defp finalize_failure(config, target, %{success: false} = result) do
    failure(config, target, :check_failed, result.failed_at_index, result.failure_reason)
  end

  defp finalize_failure(_config, _target, _result), do: nil

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

  defp failure(config, %Target{} = target, kind, root, reason) do
    %{kind: kind, variant: variant_of(target), run: config.run_number, root: root, reason: reason}
  end

  defp variant_of(%Target{index: index, name: name}), do: %{index: index, name: name}
end
