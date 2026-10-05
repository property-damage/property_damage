defmodule PropertyDamage.Differential do
  @moduledoc """
  Differential testing for comparing multiple implementations.

  Differential testing runs the same command sequences against multiple targets
  (adapters) and compares results. This enables:

  - **Oracle testing**: Compare SUT against a reference implementation
  - **Performance comparison**: Compare latency/throughput across implementations
  - **Regression testing**: Compare old vs new versions
  - **Migration validation**: Compare legacy vs new systems

  ## Basic Usage

      # Oracle testing (correctness comparison)
      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [
          OracleAdapter,
          {SUTAdapter, name: "new-impl"}
        ],
        compare: :correctness
      )

      # Performance comparison
      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [
          {ImplA, name: "redis-backend"},
          {ImplB, name: "postgres-backend"}
        ],
        compare: :performance
      )

  ## Same Adapter, Different Configurations

  A key use case is comparing the same adapter with different configurations.
  Give each target a distinct `name:` and its own `config:`:

      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [
          {HTTPAdapter, name: "prod", config: %{base_url: "https://prod.example.com"}},
          {HTTPAdapter, name: "staging", config: %{base_url: "https://staging.example.com"}}
        ],
        compare: :correctness
      )

  When both targets run against one system, use `config:` to isolate their
  slices of state (for example a tenant per target); otherwise the variants
  share state and the comparison measures interference.

  The first target is the reference: every other target is compared against it.

  ## Lockstep runs

  Each run generates one command sequence and runs it against every target in
  lockstep (`PropertyDamage.Scheduler`): every target executes command `r`,
  the targets' answers to it are compared, and only then does any target start
  command `r + 1`. Each target runs in its own process with the full engine:
  checks, settle, nemesis, stutter, and its own per-target `injectors:` and
  `mocks:`. An adapter may start resource pollers through
  `runtime.start_poller`; their events reach that target only.

  `concurrency:` decides how the targets reach each command boundary:

  - `:serial` (default) - one target at a time, in target order
  - `:parallel` - all targets at once; targets that share a system need
    isolated slices of it through their `config:`. `compare: :performance`
    and `:both` require `:serial`, because overlapping targets would mix their
    load into each other's latency.

  Every target is set up at the start of every run and torn down at its end,
  each in its own process, setups one after another in target order. An
  adapter's `setup/1` therefore runs once per run and must be idempotent.

  ## Divergences and failures

  A target diverges at the first command whose answer is not equivalent to the
  reference's answer. The run stops there, the divergence is recorded, and the
  next run starts; `divergences` lists them oldest first. Each divergence names
  the run, the command index (`root`), the command, the divergent target
  (`variant: %{index, name}`), both answers, and every target's answer by name.

  A failure in any target ends the whole campaign (later runs are not started):
  a setup error (`:setup_failed`), a failing check (`:check_failed`), or an
  adapter raise (`:execution_failed`). The result then has `status: :failed`
  and a `failure` map naming the target, run and command index; divergences
  found in earlier runs stay listed. Nothing is shrunk.

  ## Equivalence Strategies

  For correctness comparison:

  - `:exact` - Results must be identical (default)
  - `:structural` - Ignore common non-deterministic fields (id, timestamps)
  - Custom function - `fn ref_result, target_result -> boolean`
  """

  alias PropertyDamage.Differential.Result
  alias PropertyDamage.{Generator, Options, Scheduler, Sequence, Telemetry}
  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{DifferentialResult, DifferentialUpdate, Reporter}

  @type compare_mode :: :correctness | :performance | :both

  @type equivalence_strategy :: :exact | :structural | (term(), term() -> boolean())

  @doc """
  Run differential testing against multiple targets.

  ## Required Options

  - `:model` - Model module implementing PropertyDamage.Model
  - `:targets` - List of target entries (see Target Entries below)
  - `:compare` - Comparison mode: `:correctness`, `:performance`, or `:both`

  ## Target Entries

  Each entry is an adapter module or `{AdapterModule, keyword}` (see
  `PropertyDamage.Target`). The first entry is the reference.

  - `name:` - Display name for reporting (default: last segment of the module name)
  - `config:` - Map passed to the adapter's `setup/1`
  - `injectors:` - Injector adapters set up for this target only, per run
  - `mocks:` - Mock services set up for this target only, per run

  Examples:

      MyAdapter
      {MyAdapter, name: "staging"}
      {MyAdapter, name: "prod", config: %{url: "http://prod"}}

  ## Optional Options

  - `:max_commands` - Maximum commands per sequence (default: 50)
  - `:max_runs` - Number of test sequences to run (default: 100)
  - `:seed` - Random seed for reproducibility
  - `:concurrency` - `:serial` (default) or `:parallel`; see "Lockstep runs"
  - `:equivalence` - Equivalence strategy (default: `:exact`)
  - `:metrics` - Performance metrics to collect (default: `[:latency, :throughput]`)
  - `:percentiles` - Latency percentiles (default: `[50, 95, 99]`)
  - `:warmup_runs` - Runs to discard before measuring (default: 0)
  - `:verbose` - Print progress (default: false)
  - `:on_progress` - Progress consumer (DR-022). A 1-arity function called with a
    `%PropertyDamage.Progress{}` per run (`data: %DifferentialUpdate{}`) and
    once at the end with the terminal result (`data: %DifferentialResult{}`).

  ## Returns

  `{:ok, %Result{}}`. `status` is `:equivalent`, `:divergent` (see
  `divergences`, oldest first) or `:failed` (see `failure`). Under
  `compare: :performance` or `:both`, `metrics` holds each target's latency of
  every command in the measured runs, keyed by target name.
  """
  @spec run(keyword()) :: {:ok, Result.t()}
  def run(opts) do
    config = opts |> Options.validate_differential!() |> build_config()

    # Execution-time randomness of the caller; sequence generation is seeded
    # explicitly per run, and each target seeds its own process.
    :rand.seed(:exsss, config.seed)

    result = config |> run_campaign() |> build_result(config)

    # Terminal notification (DR-022): a copy of the authoritative result for
    # consumers. The returned `{:ok, result}` remains the source of truth.
    Reporter.emit(config.reporter, fn -> %DifferentialResult{result: result} end)

    {:ok, result}
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  defp build_config(opts) do
    # Unified progress projection (DR-022): one reporter fans out to the verbose
    # printer (if any), the user `on_progress:` callback (if any), and telemetry
    # (only when a handler is attached). With no consumers it is inert and no
    # %Progress{} is built.
    reporter =
      Reporter.new([
        if(opts[:verbose], do: verbose_consumer()),
        opts[:on_progress],
        Telemetry.progress_consumer([:differential])
      ])

    %{
      model: opts[:model],
      targets: opts[:targets],
      compare: opts[:compare],
      max_commands: opts[:max_commands],
      max_runs: opts[:max_runs],
      seed: opts[:seed] || :rand.uniform(1_000_000_000),
      # One run nonce shared by all targets (DR-034): every target receives
      # byte-identical client-minted requests (correct like-for-like), yet the
      # values are unique per differential run on a shared SUT.
      run_nonce: opts[:run_nonce] || :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned(),
      concurrency: opts[:concurrency],
      equivalence: opts[:equivalence],
      warmup_runs: opts[:warmup_runs],
      measure_latency: opts[:compare] in [:performance, :both],
      reporter: reporter
    }
  end

  # The `verbose:` consumer: one line per run heartbeat. The terminal
  # DifferentialResult has no verbose rendering.
  defp verbose_consumer do
    fn
      %Progress{data: %DifferentialUpdate{phase: :run} = update} ->
        IO.puts("Run #{update.run_number}/#{update.total_runs}: #{update.command_count} commands")

      %Progress{} ->
        :ok
    end
  end

  # ============================================================================
  # Runs
  # ============================================================================

  # Runs one sequence after another until max_runs or the first failure.
  # Returns the divergences (oldest first), the failure (or nil), and the
  # measurements of every measured run.
  defp run_campaign(config) do
    generator = Generator.generate_sequence(config.model, max_commands: config.max_commands)
    initial = %{divergences: [], failure: nil, samples: []}

    0..(config.max_runs - 1)//1
    |> Enum.reduce_while(initial, fn run_number, acc ->
      commands =
        generator
        |> Generator.generate_value(Generator.run_seed(config.seed, run_number))
        |> Sequence.to_list()

      # Per-run heartbeat (DR-022). run_number is reported 1-based for consumers.
      Reporter.emit(config.reporter, fn ->
        %DifferentialUpdate{
          phase: :run,
          run_number: run_number + 1,
          total_runs: config.max_runs,
          command_count: length(commands)
        }
      end)

      {:ok, run} = Scheduler.run(scheduler_opts(config, commands, run_number))
      acc = record_run(acc, config, run_number, run)

      if run.failure, do: {:halt, %{acc | failure: run.failure}}, else: {:cont, acc}
    end)
    |> Map.update!(:divergences, &Enum.reverse/1)
  end

  defp scheduler_opts(config, commands, run_number) do
    [
      model: config.model,
      targets: config.targets,
      commands: commands,
      seed: config.seed,
      run_number: run_number,
      run_nonce: config.run_nonce,
      concurrency: config.concurrency,
      compare: config.compare,
      equivalence: config.equivalence,
      measure_latency: config.measure_latency
    ]
  end

  defp record_run(acc, config, run_number, run) do
    divergences =
      if run.divergence, do: [run.divergence | acc.divergences], else: acc.divergences

    samples =
      if config.measure_latency and run_number >= config.warmup_runs do
        [run_samples(config, run) | acc.samples]
      else
        acc.samples
      end

    %{acc | divergences: divergences, samples: samples}
  end

  # Each set-up target's per-command latencies and observations of one run,
  # keyed by target name.
  defp run_samples(config, run) do
    [config.targets, run.latencies, run.observations]
    |> Enum.zip()
    |> Map.new(fn {target, latencies, observations} ->
      {target.name,
       %{
         timings: Enum.map(latencies, &elem(&1, 1)),
         results: Enum.map(observations, &elem(&1, 1))
       }}
    end)
  end

  # ============================================================================
  # Metrics
  # ============================================================================

  defp calculate_metrics(%{measure_latency: false}, _samples), do: %{}

  defp calculate_metrics(config, samples) do
    for target <- config.targets, into: %{} do
      runs = for run <- samples, data = run[target.name], do: data
      {target.name, target_metrics(runs)}
    end
  end

  defp target_metrics(runs) do
    all_timings =
      runs
      |> Enum.flat_map(& &1.timings)
      |> Enum.sort()

    if all_timings != [] do
      %{
        latency_p50: percentile(all_timings, 50),
        latency_p95: percentile(all_timings, 95),
        latency_p99: percentile(all_timings, 99),
        latency_mean: mean(all_timings),
        latency_min: Enum.min(all_timings),
        latency_max: Enum.max(all_timings),
        total_commands: length(all_timings),
        error_count: count_errors(runs),
        error_rate: error_rate(runs)
      }
    else
      %{error: :no_data}
    end
  end

  defp percentile(sorted_list, p) when sorted_list != [] do
    k = p / 100.0 * (length(sorted_list) - 1)
    f = :erlang.trunc(k)
    c = f + 1

    if c >= length(sorted_list) do
      Enum.at(sorted_list, f)
    else
      d0 = Enum.at(sorted_list, f) * (c - k)
      d1 = Enum.at(sorted_list, c) * (k - f)
      d0 + d1
    end
  end

  defp mean(list) when list != [] do
    Enum.sum(list) / length(list)
  end

  defp count_errors(runs) do
    runs
    |> Enum.flat_map(& &1.results)
    |> Enum.count(&match?({:error, _}, &1))
  end

  defp error_rate(runs) do
    total = runs |> Enum.flat_map(& &1.results) |> length()

    if total > 0 do
      count_errors(runs) / total
    else
      0.0
    end
  end

  # ============================================================================
  # Result Building
  # ============================================================================

  defp build_result(campaign, config) do
    [reference | _] = config.targets

    %Result{
      mode: config.compare,
      concurrency: config.concurrency,
      runs: config.max_runs,
      seed: config.seed,
      reference: %{index: reference.index, name: reference.name},
      status: status(campaign),
      divergences: campaign.divergences,
      failure: campaign.failure,
      metrics: calculate_metrics(config, campaign.samples),
      targets: Enum.map(config.targets, &%{index: &1.index, name: &1.name})
    }
  end

  defp status(%{failure: failure}) when failure != nil, do: :failed
  defp status(%{divergences: []}), do: :equivalent
  defp status(_campaign), do: :divergent
end
