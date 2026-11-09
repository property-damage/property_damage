defmodule PropertyDamage do
  @moduledoc """
  PropertyDamage is a stateful property-based testing framework for Elixir.
  It generates random sequences of commands, runs them against a real system,
  checks invariants as the run proceeds, and shrinks any failure to a minimal
  reproduction.

  ## Overview

  Ordinary property-based testing generates random inputs. Stateful testing
  generates random *sequences of operations* and checks that the system under
  test (SUT) behaves correctly throughout each sequence.

  You implement four behaviours and name each system to test as a target
  entry. The framework owns the rest: generation, execution, comparison,
  shrinking and reporting.

  - **Command** (`PropertyDamage.Command`) says what an operation is: its
    fields and a generator for them.
  - **Model** (`PropertyDamage.Model`) says when each command may run and
    with which arguments.
  - **Projection** (`PropertyDamage.Model.Projection`) folds events into state
    (applies each event, in order, to a running state) and judges that state.
  - **Adapter** (`PropertyDamage.Adapter`) says how to send a command to the
    system.
  - **Target** (`PropertyDamage.Target`) names one system to run against: an
    adapter plus its configuration. Its `injectors:` list names modules that
    push events into the run. You give it as a `targets:` entry; it is not a
    module you write.

  ## Two-Phase Execution

  A run has two phases.

  1. **Symbolic phase.** The framework draws a command sequence from a seed.
     The model's simulator (`PropertyDamage.Model.Simulator`) predicts the
     events of each command, so later commands can depend on earlier ones.
     This phase never touches the system.
  2. **Concrete phase.** The framework executes the sequence against each
     target and folds the real events into the projections.

  The split matters for shrinking. The plan is a pure function of the seed, so
  the shrinker (`PropertyDamage.Shrinker`) can re-run any smaller plan and get
  a meaningful answer.

  ## One Engine

  Every kind of run goes through `PropertyDamage.run/1`: a property run against
  one system, a differential run that compares several systems, and a
  path-equivalence run that reaches one system by two command paths and
  compares the outcomes. `run/1` hands the options to the campaign loop
  (`PropertyDamage.Campaign`), which draws each sequence from the seed. For
  each generated sequence, the run driver `PropertyDamage.Runner` calls
  `PropertyDamage.Scheduler`, which starts one
  `PropertyDamage.Variant` process per target (it runs that target's copy of
  the sequence) and advances them in lockstep (one step at a time, all targets
  together).
  Each variant executes one command at a time through
  `PropertyDamage.Executor.Stepping`, and the scheduler compares the targets'
  observations after each root. The shrinker's candidates and the
  reproduction of a failure run through the same run driver. A root is a
  top-level generated command; an expansion is a command that unfolds into
  child commands under a root.

  ## Symbolic Values

  Some values exist only after the system creates them, such as an order id.
  Mark that event field with `external()` (see `PropertyDamage.External`).
  During simulation the field becomes a `%PropertyDamage.Placeholder{}`, and
  commands generated later can use it. In the concrete phase, the framework
  replaces each placeholder with the value from the real event before the
  command that uses it runs.

  ## Where Checks Run

  A projection declares its checks with module attributes.

  - `@check` judges the projection state right after events fold, at the points
    named by `every:` or `at:`.
  - `@eventually` polls a predicate until it holds or a timeout ends the
    window. Use it when the system settles later.
  - `@compare` returns a value that the framework compares across targets after
    each root.

  See `PropertyDamage.Model.Projection` for the exact options.

  ## Where to Look

  - `PropertyDamage.Generator` and `PropertyDamage.Expansion`: generate command
    sequences.
  - `PropertyDamage.Scheduler`, `PropertyDamage.Variant` and
    `PropertyDamage.Executor`: run a sequence on one or more targets.
  - `PropertyDamage.Settle`: retries commands on eventually consistent systems.
  - `PropertyDamage.Shrinker`: reduces a failing sequence.
  - `PropertyDamage.RunTrace`, `PropertyDamage.Failure` and
    `PropertyDamage.FailureReport`: record what a run did and why it failed.
  - `PropertyDamage.Persistence`, `PropertyDamage.Replay` and
    `PropertyDamage.Export`: save, replay and export failures.
  - `PropertyDamage.Coverage`, `PropertyDamage.Mutation` and
    `PropertyDamage.LoadTest`: measure how well a model exercises the system.

  ## Basic Usage

      defmodule MyModelTest do
        use ExUnit.Case
        use PropertyDamage.ExUnit

        property_damage "system maintains invariants",
          model: MyApp.TestModel,
          targets: [MyApp.TestAdapter],
          max_commands: 50,
          max_runs: 100
      end

  ## Running Directly

      PropertyDamage.run(
        model: MyApp.TestModel,
        targets: [MyApp.TestAdapter],
        max_commands: 50,
        max_runs: 100
      )

  ## Debugging Failures

  When a test fails, PropertyDamage provides rich tools for understanding what went wrong:

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Understand why each command in the shrunk sequence is needed
      explanation = PropertyDamage.explain(failure)

      # Find the specific field/value that caused the failure
      {:ok, trigger} = PropertyDamage.isolate_trigger(failure)

      # Generate a reproducible test case
      test_code = PropertyDamage.generate_test(failure, format: :exunit)

      # Try harder to shrink if needed
      {:ok, smaller} = PropertyDamage.shrink_further(failure, strategy: :exhaustive)

      # Replay step-by-step
      {:ok, steps} = PropertyDamage.replay(failure)

  ## Failure Persistence

  Save failures for later analysis or regression testing:

      {:ok, path} = PropertyDamage.save_failure(failure, "failures/")
      {:ok, loaded} = PropertyDamage.load_failure(path)
      failures = PropertyDamage.list_failures("failures/")

  See `PropertyDamage.Persistence` for details.

  ## Seed Library

  Replay recently-failing seeds before random exploration (DR-023). This is an
  ephemeral, self-pruning working set for the fix cycle, not a durable corpus
  (for durable regressions, export to an ExUnit test):

      # Replay failing seeds first; append any new failure's seed automatically
      PropertyDamage.run(model: M, targets: [A], seed_library: true)

  See `PropertyDamage.SeedLibrary` for details.

  ## Coverage Metrics

  Track how thoroughly your model is being exercised. `coverage: true` attaches
  the tracker to the success stats as `:coverage`; a passing result without it
  raises `ArgumentError`:

      result = PropertyDamage.run(model: MyModel, targets: [MyAdapter], coverage: true)
      coverage = PropertyDamage.coverage(result, MyModel)
      IO.puts(PropertyDamage.Coverage.format(coverage))

  See `PropertyDamage.Coverage` for details.

  ## Flakiness Detection

  Detect non-deterministic behavior in your SUT by running one plan many times
  and localizing where the passing and failing runs diverge:

      {_traces, comparison} =
        PropertyDamage.RunComparison.investigate(
          runs: 10,
          capture: [model: Model, targets: [Adapter], seed: seed]
        )

  The `capture:` option holds the options of
  `PropertyDamage.RunTrace.Capture.capture/1`, which records one run in full as a
  `PropertyDamage.RunTrace`.

  Scan a whole corpus of seeds with `PropertyDamage.RunComparison.scan/1`. See
  `PropertyDamage.RunComparison` for details.
  """

  alias PropertyDamage.{
    Campaign,
    EventQueue,
    Executor,
    Failure,
    FailureReport,
    Options,
    Reproduction,
    Scheduler,
    Sequence
  }

  alias PropertyDamage.Runtime.RunServices

  @typedoc """
  Result statistics from a successful run.
  """
  @type stats :: %{
          required(:runs) => non_neg_integer(),
          required(:total_commands) => non_neg_integer(),
          required(:seed) => integer(),
          required(:targets) => [%{index: non_neg_integer(), name: String.t()}],
          optional(:check_fires) => %{{module(), atom()} => non_neg_integer()},
          optional(:compare_counts) => Scheduler.compare_counts(),
          optional(:coverage) => term(),
          optional(:metrics) => %{String.t() => map()}
        }

  @typedoc """
  Failure report from a failed run.
  """
  @type failure_report :: %{
          seed: integer(),
          run_number: non_neg_integer(),
          original_sequence: Sequence.t(),
          failed_at_index: non_neg_integer(),
          failure_reason: term(),
          shrink_iterations: non_neg_integer(),
          shrink_time_ms: non_neg_integer()
        }

  @typedoc """
  Result from `run/1` - either success stats or a failure report.
  """
  @type result :: {:ok, stats()} | {:error, failure_report()}

  @doc """
  Run a property-based test.

  This is the main entry point for PropertyDamage. It generates command sequences,
  executes them against the SUT, and shrinks failures to minimal reproductions.

  ## Required Options

  - `:model` - Model module implementing PropertyDamage.Model
  - `:targets` - The systems under test, as a list of adapter modules
    implementing PropertyDamage.Adapter or
    `{AdapterModule, name:, config:, injectors:, mocks:}` entries. See
    `PropertyDamage.Target`. With one entry the run tests that system; with
    several, the first is the reference and every other target is compared
    with it command by command (see "Several Targets" below).

  ## Optional Options

  - `:max_commands` - Maximum commands per sequence (default: 50)
  - `:max_runs` - Number of test sequences to run (default: 100)
  - `:seed` - Random seed for reproducibility (default: random)
  - `:shrink` - Whether to shrink failing sequences (default: true; `false`
    under `only: [replay: path]`)
  - `:run_nonce` - A 64-bit integer that seeds the values the client mints for
    a run (default: strong random entropy). Hold the seed and vary the nonce to
    run the same plan with fresh minted values on a shared system
  - `:only` - Run part of a campaign: `[run: n, variants: names,
    with_reference: boolean]` runs run `n` of the seed alone, and
    `[replay: path]` runs a replay artifact (default: the whole campaign)
  - `:replay_dir` - The directory a failing run writes its replay artifact
    into, created when missing (default: `"property_damage_replays"`); `false`
    writes none
  - `:coverage` - Accumulate the command, transition and state coverage of the
    whole run and attach the tracker to the success stats as `:coverage`
    (default: false)
  - `:external_markers` - Extra atoms to treat as `external()` markers, for
    domain libraries that mark server-generated fields without depending on
    PropertyDamage (default: `[]`)
  - `:on_progress` - Callback receiving `%PropertyDamage.Progress{}` updates
    during the run and a final result (default: nil)
  - `:seed_library` - Ephemeral replay working set (DR-023): `false` (default,
    disabled), `true` (default file), or a path. Previously-failing seeds are
    replayed before exploration; a still-failing replay halts the run.
  - `:seed_library_prune_after` - Consecutive passing replays after which a seed
    is dropped from the library (default: 3)
  - `:shrinker_config` - ShrinkerConfig struct for tuning shrinking
  - `:on_failure` - Callback function receiving failure_report (default: nil)
  - `:regression` - Keyword list for automatic regression test management (see below)
  - `:verbose` - Print progress and configuration (default: false)
  - `:validate` - Run configuration validation first (default: true)
  - `:stutter` - Keyword list for idempotency testing (see below)
  - `:check_mode` - How a failing check is handled: `:halt` (default),
    `:record`, `:log` or `:disabled`
  - `:setup_log` - The lines `PropertyDamage.Log.capture/1` returned for work
    done before the run, such as seeding the system (default `[]`). The report
    prints them once, in a Setup section before the reproduction, labeled as
    shared by every run.
  - `:report_html` - A directory a failing run writes its report into as an
    HTML page, beside an `index.html` that browses every page there (default
    `false`). The environment variable `PD_REPORT_HTML` replaces it. See
    `PropertyDamage.FailureReport.HTML`.
  - `:log` - `[keep_attempts: n, only: tags, except: tags]`. `keep_attempts`
    is how many of a step's last settle or stutter attempts keep their log
    lines besides the first attempt (default `3`); the report prints each gap
    as `... N attempts omitted (M lines)`. `only:` and `except:` are
    non-empty lists of tag atoms that hide whole log lines from the printed
    report: `only:` shows the lines that carry a listed tag, `except:` hides
    them and wins, and a line with no tag always shows. The report prints the
    filter and warns about a listed tag no line carries. A filter hides lines
    from one reader and protects no secret (redact in the code that logs);
    the environment variable `PD_LOG`, for example
    `PD_LOG="only:http,seed except:body"`, replaces it. See
    `PropertyDamage.Log.Filter`.
  - `:concurrency` - How the targets reach each command boundary: `:serial`
    (default) steps one target at a time in target order; `:parallel` steps
    every target at once
  - `:compare` - `[converge_within: ms]`: how long the comparison of two or
    more targets waits at a boundary for their `@compare` observations to
    agree (default `[converge_within: 5_000]`)
  - `:latency` - Measures each target's latency per command and returns it
    in `stats.metrics` (default `false`); requires `concurrency: :serial`.
    `true` only measures. A keyword list adds `warmup: n` (the first `n` runs
    are left out of the metrics, default `0`) and a budget judged once after
    the last run (see "Latency Budget")

  ## Several Targets

  Each linear run executes its command sequence against every target in
  lockstep (`PropertyDamage.Scheduler`): every target executes command `r`,
  their boundary observations scheduled there are compared, and only once they
  agree does any target start command `r + 1`. Targets are compared only
  through the functions the model's projections mark with `@compare`: a run
  with two or more targets whose model declares none is an error before any
  adapter is set up. Each target runs in its own process with its own event queue,
  injectors, mocks and pollers, and is set up and torn down once per run.
  `latency:` requires `concurrency: :serial`, because overlapping targets
  would mix their load into each other's latency.

  A model's fixtures are commands: `c:PropertyDamage.Model.setup_each/0` lists
  the setup commands and `c:PropertyDamage.Model.teardown_each/0` the teardown
  commands, generated with each run's sequence. Every target executes them through
  the engine, in this order per run: its adapter's `setup/1`, the `@check at:
  :startup` checks, the setup commands, the roots, the final boundary, the
  `@check at: :teardown` checks, the teardown commands, and its adapter's
  `teardown/1`. Every path that executes the run again (each shrink attempt,
  the reproduction, `shrink_further/2`, the seed-library
  replay, `replay/2`) runs them the same way; the shrinker never removes or
  simplifies a setup command and draws the teardown commands again for each
  candidate. A failing setup command, a check that fails on a setup
  command's event, or an `external()` a setup command produces that stays
  unresolved is a setup failure (`report_kind: :setup_failed`).

  ## Latency Budget

  `latency:` takes any of `p50`, `p95`, `p99` and `mean`, each a keyword list
  with `max: {n, :milliseconds | :seconds | :minutes}` (an absolute bound, `n`
  a positive integer) and/or `max_ratio: ratio` (a positive number: the
  target's statistic divided by the reference's). A bare integer has no unit
  and is an option error.

      latency: [warmup: 2, p95: [max_ratio: 1.5], p99: [max: {800, :milliseconds}]]

  The budget is judged once, after the last run passes, on the metrics of the
  measured runs: every target is judged on `max:`, every target but the
  reference on `max_ratio:` (which needs at least two targets). A breach ends
  the campaign with a report of `report_kind: :latency_exceeded`. It names the target,
  the statistic, the measured value and the limit, and it is neither shrunk nor
  re-executed: latency is statistical, so re-run the seed to reproduce it. A run
  that fails for another reason ends the campaign first, and the budget is
  never judged.

  The metrics of each target are `p50`, `p95`, `p99`, `mean`, `min` and `max`
  in microseconds, `commands` (the commands timed) and `by_command` (`p95` and
  `commands` per root command module). A target with no timed command has
  `%{error: :no_data}` and is never judged.

  The first failure ends the campaign: a target whose boundary observation
  still differs from the reference's at the convergence bound
  (`report_kind: :diverged`) or is still pending there (`report_kind: :did_not_converge`), a
  failing check in any target, a setup failure or an execution failure. The
  report names the target in `variant`.

  A failure is shrunk and reproduced the same way for one target or several:
  every shrink attempt runs the candidate sequence on every target through the
  scheduler (each target set up and torn down per attempt), and a candidate
  counts only if it fails with the same kind, check name and failing target
  (`PropertyDamage.Failure.signature/2`). The shrunk sequence is then
  run once more, and the report describes that reproduction; when it does not
  fail the same way, the report keeps the original run. A setup failure
  implicates no command and is reported unshrunk.

  ## Stutter Options (Idempotency Testing)

  Pass `stutter: [...]` to enable idempotency testing:

  - `:probability` - Probability of stuttering each command (default: 0.1)
  - `:max_repeats` - Maximum retry attempts per stuttered command (default: 2)
  - `:delay_ms` - Delay between retries, `{min, max}` tuple or integer (default: {0, 100})
  - `:commands` - `:all` or list of command modules to stutter (default: :all)
  - `:using` - The relation deciding whether a retry agrees with the
    original: `{Mod, :fun}`, called `Mod.fun(original_events, retry_events)`,
    `{Mod, :fun, args}`, or a 2-arity function, with the verdict contract of
    `@compare`'s `using:` (default `==`)

  Stutter testing verifies that retrying commands produces consistent results
  (idempotency). Retry events are captured but not applied to projections.

  ## Regression Options

  Pass `regression: [...]` to automatically save failures for regression testing:

  - `:save_failures` - Directory to save failure files
  - `:seed_library` - Path to seed library JSON file
  - `:generate_tests` - Directory to generate ExUnit test files
  - `:tags` - Tags to add to seed library entries (default: `[:auto_detected]`)
  - `:dedup` - Skip if similar failure exists (default: false)
  - `:dedup_threshold` - Similarity threshold for dedup (default: 0.90)
  - `:verbose` - Print regression actions (default: false)
  - `:targets` - Single-entry target for generated regression tests (default:
    the run's target)

  This option integrates with `:on_failure` - both can be used together.

  ## Returns

  - `{:ok, stats}` - All runs passed. `stats` holds `runs`, `total_commands`,
    `seed`, `targets` (`[%{index:, name:}]`), the coverage keys,
    `compare_counts` (per `@compare` key `{projection, function}`: the
    boundaries it was compared at, waited at, and the time waited), and under
    `latency:` the latency `metrics` of each target, keyed by target name
  - `{:error, failure_report}` - A run failed; see `PropertyDamage.FailureReport`
    for its `kind` and the failing `variant`. A target whose adapter `setup/1`
    fails is a report of kind `:setup_failed`

  ## Target Entry Keys

  - `:name` - Label used in reports (default: last segment of the module name)
  - `:config` - Map passed to `adapter.setup/1` (default: `%{}`)
  - `:injectors` - List of `PropertyDamage.Adapter.Injector` modules for event injection
    (default: `[]`)
  - `:mocks` - Mock third-party services the SUT calls (default: `[]`).
    A list of `PropertyDamage.MockServiceAdapter` modules or `{module, config}`
    tuples. Per run the framework starts a `PropertyDamage.MockServiceRegistry`,
    registers and sets up each mock, drives `on_command/2` before each command,
    folds mock-injected events after, and tears each mock down. The registry pid
    is handed to the adapter on the `PropertyDamage.Runtime` handle
    (`runtime.mock_registry`) so `execute/3` can drive `handle_request/2`. See
    the "Mocking Third-Party Services" guide.
  - `:expansion` - How this target chooses among a root's expansions:
    `:random` (default), `:identity` or `:reference`. See
    `PropertyDamage.Target`.

  ## Examples

      # Basic usage
      PropertyDamage.run(model: MyModel, targets: [MyAdapter])

      # With options
      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        max_commands: 100,
        max_runs: 1000,
        seed: 12345
      )

      # With failure callback
      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        on_failure: fn failure_report ->
          IO.puts("Failed at command \#{PropertyDamage.FailureReport.failure_index(failure_report)}")
        end
      )

      # With automatic regression management
      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        regression: [
          save_failures: "failures/",
          seed_library: "seeds.json",
          generate_tests: "test/regressions/",
          dedup: true
        ]
      )
  """
  @spec run(keyword()) :: {:ok, stats()} | {:error, failure_report()}
  def run(opts), do: Campaign.run(opts, &on_failure_callback/1)

  # The `on_failure` callback of a run: its `:on_failure` and `:regression`
  # options, composed when both are given, or `nil` when neither is set.
  defp on_failure_callback(opts) do
    on_failure = Keyword.get(opts, :on_failure)
    regression = Keyword.get(opts, :regression)

    cond do
      # Both options specified - compose them
      on_failure != nil and regression != nil ->
        regression_handler =
          PropertyDamage.Regression.handler(Options.with_target_entries(regression))

        fn failure_report ->
          on_failure.(failure_report)
          regression_handler.(failure_report)
        end

      # Only on_failure specified
      on_failure != nil ->
        on_failure

      # Only regression specified
      regression != nil ->
        PropertyDamage.Regression.handler(Options.with_target_entries(regression))

      # Neither specified
      true ->
        nil
    end
  end

  @doc """
  Attempt further shrinking on an existing failure report.

  Use this when the initial shrinking didn't produce a minimal enough sequence.
  You can specify more aggressive time/iteration limits or different strategies.

  The re-shrink runs exactly as the run's own shrinking does: every candidate
  runs on every target through the lockstep scheduler, and a candidate counts
  only if it fails with the report's kind, check name and failing target. The
  smaller sequence is then reproduced once; a report whose shrunk sequence does
  not reproduce comes back unchanged. A `:setup_failed` report implicates no
  command and comes back unchanged.

  For a model with `expansions/0`, the re-shrink starts from what every
  target ran, read from the report's `replay` term (the term its replay
  artifact holds), or from the choices its trace records when it has no
  term; it works for every target the report records. It raises
  `ArgumentError`, naming `replay_dir:`, only when the report holds neither a
  `replay` term nor `expansions`. The new report's `expansions` and
  `expansion_counts` describe the further-shrunk run, and its `replay` term
  holds it: when the report came with an artifact file, the new artifact
  replaces that file.

  ## Options

  - `:strategy` - Shrinking strategy (default: `:thorough`). Each strategy sets a
    default budget that the explicit options below override:

    | strategy       | max_iterations | max_time_ms |
    |----------------|----------------|-------------|
    | `:quick`       | 500            | 10_000      |
    | `:thorough`    | 2000           | 60_000      |
    | `:exhaustive`  | 10_000         | 300_000     |

  - `:max_iterations` - Maximum shrink attempts (default: from `:strategy`)
  - `:max_time_ms` - Maximum time for shrinking in ms (default: from `:strategy`)
  - `:shrink_arguments` - Whether to shrink argument values (default: true)
  - `:targets` - One or more target entries overriding the systems to
    re-execute against, reference first (default: the report's `targets`); see
    `PropertyDamage.Target`
  - `:concurrency` - `:serial` or `:parallel`, as on `PropertyDamage.run/1`
    (default: the report's `concurrency`)
  - `:compare` - `[converge_within: ms]`, as on `PropertyDamage.run/1`
    (default: the report's `compare`)
  - `:log` - `[keep_attempts: n]`, as on `PropertyDamage.run/1`: how many of a
    step's last settle or stutter attempts keep their log lines in the new
    report (default 3). The report does not record the run's value, so a run
    given another value passes it here again.
  - `:external_markers` - The atom markers of the run, as on
    `PropertyDamage.run/1` (default: the report's `external_markers`, the
    markers the run named). The re-shrink simulates the report's commands
    again, and only a marker in this list turns an event field into a
    placeholder that later commands resolve.

  The re-shrink also uses the report's `stutter` configuration: a stutter
  failure re-runs with stutter forced on, as the run's own shrink does.

  ## Returns

  - `{:ok, new_failure_report}` - Shrinking succeeded, possibly smaller sequence
  - `{:error, reason}` - Shrinking failed: `:missing_model_or_target` when the
    report records no model or no target; `{:variant_not_in_targets, name}`
    when the `targets:` option does not hold the target the report failed in
    (`name`) at the index it failed at, because it renamed, dropped or moved
    that target; or the setup `%PropertyDamage.Failure{}` when a target's
    adapter `setup/1` fails on the re-execution

  An `{:ok, report}` holding the incoming report unchanged means no smaller
  sequence reproduced the failure (or the report is a `:setup_failed` or
  `:latency_exceeded` one, which re-shrinking leaves as it is).

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Try harder to shrink
      {:ok, smaller} = PropertyDamage.shrink_further(failure,
        max_time_ms: 120_000,
        strategy: :exhaustive
      )

      alias PropertyDamage.{FailureReport, Sequence}
      before = failure |> FailureReport.shrunk_sequence() |> Sequence.command_count()
      after_count = smaller |> FailureReport.shrunk_sequence() |> Sequence.command_count()
      IO.puts("Reduced from \#{before} to \#{after_count} commands")
  """
  @spec shrink_further(FailureReport.t(), keyword()) ::
          {:ok, FailureReport.t()} | {:error, term()}
  def shrink_further(report, opts \\ []),
    do: Reproduction.shrink_further(report, opts, "PropertyDamage.shrink_further/2")

  @doc """
  Explain why each command in a failure's shrunk sequence is needed.

  Delegates to `PropertyDamage.Analysis.explain/1`.
  See that module for detailed documentation.
  """
  @spec explain(FailureReport.t()) :: map()
  defdelegate explain(report), to: PropertyDamage.Analysis

  @doc """
  Find the minimal change that eliminates the failure.

  Delegates to `PropertyDamage.Analysis.isolate_trigger/1`.
  See that module for detailed documentation.
  """
  @spec isolate_trigger(FailureReport.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate isolate_trigger(report, opts \\ []), to: PropertyDamage.Analysis

  @doc """
  Generate a reproducible test case from a failure.

  Delegates to `PropertyDamage.Analysis.generate_test/2`.
  See that module for detailed documentation.
  """
  @spec generate_test(FailureReport.t(), keyword()) :: String.t()
  defdelegate generate_test(report, opts \\ []), to: PropertyDamage.Analysis

  # ============================================================================
  # Persistence API
  # ============================================================================

  @doc """
  Save a failure report to disk for later analysis or regression testing.

  ## Options

  - `:filename` - Custom filename (default: auto-generated from metadata)
  - `:overwrite` - Whether to overwrite existing files (default: false)

  ## Examples

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Save with auto-generated name
      {:ok, path} = PropertyDamage.save_failure(failure, "failures/")

      # Save with custom name
      {:ok, path} = PropertyDamage.save_failure(failure, "failures/", filename: "currency-bug.pd")
  """
  @spec save_failure(FailureReport.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  defdelegate save_failure(report, directory, opts \\ []),
    to: PropertyDamage.Persistence,
    as: :save

  @doc """
  Load a previously saved failure report.

  Returns `{:ok, report}`, or `{:ok, report, warnings}` when the file was saved
  by a different version and may not reproduce, or `{:error, reason}`.

  ## Examples

      {:ok, failure} = PropertyDamage.load_failure("failures/currency-bug.pd")
      PropertyDamage.replay(failure)
  """
  @spec load_failure(Path.t()) ::
          {:ok, FailureReport.t()}
          | {:ok, FailureReport.t(), [PropertyDamage.Persistence.warning()]}
          | {:error, term()}
  defdelegate load_failure(path), to: PropertyDamage.Persistence, as: :load

  @doc """
  List all saved failures in a directory.

  ## Options

  - `:sort` - Sort order: `:newest`, `:oldest`, `:seed` (default: `:newest`)
  - `:filter` - Filter function `(metadata -> boolean)`

  ## Examples

      failures = PropertyDamage.list_failures("failures/")

      # Only check failures
      failures = PropertyDamage.list_failures("failures/",
        filter: &(&1.kind == :check_failed))
  """
  @spec list_failures(Path.t(), keyword()) :: [map()]
  defdelegate list_failures(directory, opts \\ []), to: PropertyDamage.Persistence, as: :list

  @doc """
  Delete a saved failure file.
  """
  @spec delete_failure(Path.t()) :: :ok | {:error, term()}
  defdelegate delete_failure(path), to: PropertyDamage.Persistence, as: :delete

  # ============================================================================
  # Replay API
  # ============================================================================

  @doc """
  Replay a failure sequence step-by-step for debugging.

  Executes each command in the shrunk sequence and returns detailed
  information about each step including events and projection states.

  ## Options

  - `:targets` - Single-entry target list overriding the system to replay
    against (default: the report's reference target)
  - `:stop_on_failure` - Stop at first failure (default: true)

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])
      {:ok, steps} = PropertyDamage.replay(failure)

      Enum.each(steps, fn step ->
        IO.puts("[\#{step.index}] \#{step.command_name}")
        IO.inspect(step.projections)
      end)

  For interactive stepping, use `PropertyDamage.Replay` directly:

      {:ok, session} = PropertyDamage.Replay.start(failure)
      {:ok, session, step} = PropertyDamage.Replay.step(session)
  """
  @spec replay(FailureReport.t(), keyword()) ::
          {:ok, [PropertyDamage.Replay.step()]} | {:error, term()}
  defdelegate replay(failure, opts \\ []), to: PropertyDamage.Replay, as: :run

  # ============================================================================
  # Seed Library API
  # ============================================================================

  @doc """
  Load a seed library from disk.

  With no argument it reads `property_damage_seeds.json` and returns an empty
  library if that file doesn't exist. A path you pass that doesn't exist
  returns `{:error, :enoent}`.

  ## Example

      {:ok, library} = PropertyDamage.load_seed_library()
      {:ok, library} = PropertyDamage.load_seed_library("seeds.json")
  """
  @spec load_seed_library(Path.t()) :: {:ok, PropertyDamage.SeedLibrary.t()} | {:error, term()}
  defdelegate load_seed_library(path \\ "property_damage_seeds.json"),
    to: PropertyDamage.SeedLibrary,
    as: :load

  @doc """
  Save a seed library to disk.

  ## Example

      :ok = PropertyDamage.save_seed_library(library, "seeds.json")
  """
  @spec save_seed_library(PropertyDamage.SeedLibrary.t(), Path.t()) :: :ok | {:error, term()}
  defdelegate save_seed_library(library, path \\ "property_damage_seeds.json"),
    to: PropertyDamage.SeedLibrary,
    as: :save

  @doc """
  Add a failure to the seed library.

  ## Options

  - `:tags` - Categorization tags (e.g., `[:currency, :race_condition]`)
  - `:description` - Human-readable description

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])
      {:ok, library} = PropertyDamage.add_to_seed_library(library, failure,
        tags: [:currency_mismatch],
        description: "Capture with different currency than authorization"
      )
  """
  @spec add_to_seed_library(PropertyDamage.SeedLibrary.t(), FailureReport.t(), keyword()) ::
          {:ok, PropertyDamage.SeedLibrary.t()} | {:error, term()}
  defdelegate add_to_seed_library(library, failure, opts \\ []),
    to: PropertyDamage.SeedLibrary,
    as: :add

  # ============================================================================
  # Coverage API
  # ============================================================================

  @doc """
  Get coverage statistics from a test result.

  Accepts both a single sequence/failure result and an aggregate `{:ok, stats}`
  from a multi-run `run/1` invoked with `coverage: true` (the latter returns the
  pre-merged `stats.coverage` tracker). An aggregate result produced without
  `coverage: true` raises `ArgumentError`.

  ## Example

      result = PropertyDamage.run(model: M, targets: [A], coverage: true)
      coverage = PropertyDamage.coverage(result, M)
      IO.puts(PropertyDamage.Coverage.format(coverage))
  """
  @spec coverage({:ok, map()} | {:error, FailureReport.t()}, module()) ::
          PropertyDamage.Coverage.t()
  defdelegate coverage(result, model), to: PropertyDamage.Coverage, as: :from_result

  @doc """
  Per-invariant anti-vacuity coverage for a run result (DR-026).

  Joins the run's per-check firings (`result.check_fires`, accumulated
  across every generated sequence) against the model's `check_catalog/1`,
  with no re-execution. Each entry reports whether the invariant was exercised:

      result = PropertyDamage.run(model: M, targets: [A])
      for inv <- PropertyDamage.check_coverage(result, M), not inv.covered? do
        IO.puts("never exercised: \#{inv.id}")
      end

  Each entry is a map with `:projection`, `:id`, `:name`, `:description`,
  `:kinds` (the distinct check kinds), `:fire_count` (summed over the invariant's
  checks), and `:covered?` (`fire_count > 0`). Ordered like the catalog. Works on
  a passing `{:ok, stats}` or a failing `{:error, report}` result, though on a
  failed run the fire map is partial by nature (anti-vacuity is a passing-run
  concern).
  """
  @spec check_coverage({:ok, map()} | {:error, FailureReport.t()} | map(), module()) :: [
          %{
            projection: module(),
            id: atom(),
            name: atom(),
            description: String.t() | nil,
            kinds: [atom()],
            fire_count: non_neg_integer(),
            covered?: boolean()
          }
        ]
  def check_coverage(result, model) do
    fires = extract_check_fires(result)

    model
    |> PropertyDamage.Model.check_catalog()
    |> Enum.map(fn %{projection: projection, id: id, invariant: invariant, checks: checks} ->
      fire_count =
        Enum.reduce(checks, 0, fn check, acc ->
          acc + Map.get(fires, {projection, check.name}, 0)
        end)

      %{
        projection: projection,
        id: id,
        name: invariant.name,
        description: invariant.description,
        kinds: checks |> Enum.map(& &1.kind) |> Enum.uniq(),
        fire_count: fire_count,
        covered?: fire_count > 0
      }
    end)
  end

  defp extract_check_fires({:ok, stats}), do: Map.get(stats, :check_fires, %{})

  defp extract_check_fires({:error, %FailureReport{check_fires: fires}}),
    do: fires || %{}

  defp extract_check_fires(%{check_fires: fires}), do: fires || %{}
  defp extract_check_fires(_), do: %{}

  @doc """
  The model's invariant catalog (DR-026).

  The union of every projection's declared invariants, keyed `{projection, id}`,
  each entry carrying the `%PropertyDamage.Invariants.Invariant{}` and the checks
  (with their kinds) that validate it. See `PropertyDamage.Model.check_catalog/1`.
  """
  @spec check_catalog(module()) :: [
          %{
            projection: module(),
            id: atom(),
            invariant: PropertyDamage.Invariants.Invariant.t(),
            checks: [%{name: atom(), kind: :synchronous | :lifecycle | :eventual}]
          }
        ]
  defdelegate check_catalog(model), to: PropertyDamage.Model

  # ============================================================================
  # Check Helpers
  # ============================================================================

  @doc """
  Convenience function to fail a check with a message and optional data.

  Use this in projection checks when you don't need a custom exception type.
  It raises `PropertyDamage.CheckFailed`, so it is the early exit from a check
  body. Its returned form is the verdict `{:fail, "message"}` (DR-052): a check
  that returns it fails with the same `PropertyDamage.CheckFailed`, so a
  reasoned check can end in `condition || {:fail, "message"}` without raising.

  ## Examples

      # Simple failure
      PropertyDamage.fail!("balance is negative")

      # With context data
      PropertyDamage.fail!("balance is negative", balance: -50, account_id: "acc_123")

      # In a projection check
      @check every: 1
      def assert_balance_positive(state, _cmd) do
        state.balance >= 0 or PropertyDamage.fail!("negative balance", balance: state.balance)
      end

  ## Custom Exceptions

  For richer error context, define your own exception types:

      defmodule MyApp.BalanceViolation do
        defexception [:balance, :requirement]

        def message(%{balance: b}) do
          "Balance is negative: \#{b}"
        end
      end

      # Then raise directly:
      raise %MyApp.BalanceViolation{balance: -50, requirement: "REQ-001"}
  """
  @spec fail!(String.t(), keyword()) :: no_return()
  def fail!(message, data \\ []) do
    raise %PropertyDamage.CheckFailed{message: message, data: Map.new(data)}
  end

  # ============================================================================
  # Log Lines
  # ============================================================================

  @doc """
  Writes one log line for the failure report (DR-054).

  A line is shown only in a failure report, under the step whose code wrote
  it, in timestamp order with that step's events, as its offset from the
  target's run start, its tags and its message:

      +0.12s log   [http url] POST /transfers

  PropertyDamage never prints a line during a run and never forwards one to
  Elixir's `Logger`. Call it behind `require PropertyDamage`; the call site's
  file and line are recorded.

  ## Message

    * a string is stored as written and printed as written;
    * any other value is stored as it was at the call and printed with
      `inspect/2` when the report is formatted;
    * a 0-arity function is called each time the report is formatted, after
      the run ended, and its result printed by the two rules above. A function
      that reads state that can change (an `Agent`, an ETS table) sees the
      value at the end of the run; one that raises prints
      `(log line raised: ...)`.

  The macro never wraps a message in a function on its own.

  ## Options

    * `:tags` - a literal list of atoms, printed in brackets before the
      message. It is the only option; any other option, a tag that is not an
      atom, or options that are not a literal keyword list is a compile error.

  ## Scope

  The call needs a scope: code PropertyDamage runs at an execution point (an
  adapter callback, a command, a mock handler), or a process
  started from it through `Task`. Anywhere else it raises
  `PropertyDamage.Log.NoScopeError`; a process the adapter did not start
  through `Task` logs with `PropertyDamage.Runtime.log/3`. See
  `PropertyDamage.Log`.

  Remove secrets before the call: every line reaches the printed report.

  ## Example

      require PropertyDamage

      def execute(%Transfer{amount: amount}, %{client: client}, _runtime) do
        PropertyDamage.log("POST /transfers", tags: [:http, :url])
        PropertyDamage.log(%{amount: amount}, tags: [:http, :body])
        {status, body} = MyApp.Client.post(client, "/transfers", %{amount: amount})
        PropertyDamage.log(fn -> Jason.decode!(body) end, tags: [:http, :response])
        {:ok, [%Transferred{amount: amount, status: status}]}
      end
  """
  defmacro log(message, opts \\ []) do
    tags = PropertyDamage.Log.__tags__!(opts, __CALLER__)
    location = {__CALLER__.file, __CALLER__.line}

    quote do
      PropertyDamage.Log.__log__(unquote(message), unquote(tags), unquote(location))
    end
  end

  # ============================================================================
  # Model-Free Execution (Static Regression Tests)
  # ============================================================================

  @doc """
  Execute a fixed command sequence without a model.

  This function provides a model-free execution path for static regression tests
  where you want to run a specific command sequence and assert on the raw event
  log directly, without using model-defined projections or checks.

  ## Use Cases

  - **Regression tests**: Run a specific sequence that reproduced a bug
  - **Integration tests**: Execute commands with real injector adapters
  - **Debugging**: Capture full SUT behavior including webhooks/callbacks

  ## Options

  - `:targets` - A list with exactly one entry (required): an adapter module or
    `{AdapterModule, config:, injectors:}`. `config:` is passed to
    `adapter.setup/1` (default: `%{}`); `injectors:` lists injector adapter
    modules (default: `[]`). `mocks:` is not supported here and raises. See
    `PropertyDamage.Target`.

  ## Returns

  - `{:ok, event_log}` - List of `EventLog.Entry` structs containing all events
  - `{:error, %PropertyDamage.Failure{}}` - a `:adapter_error` (with `partial_events`)

  ## Example

      # Simple execution
      commands = [
        %CreateUser{name: "alice"},
        %CreateOrder{user_id: 1, amount: 100}
      ]

      {:ok, events} = PropertyDamage.execute(commands, targets: [MyAdapter])

      # Assert on returned events
      assert length(events) == 2
      assert hd(events).event.__struct__ == UserCreated

  ## With Injector Adapters

  When testing end-to-end flows with webhooks or async callbacks:

      {:ok, events} = PropertyDamage.execute(commands,
        targets: [
          {MyAdapter,
           injectors: [WebhookAdapter],
           config: %{base_url: "http://localhost:4000"}}
        ]
      )

      # Assert on injected webhook events
      assert Enum.any?(events, fn entry ->
        entry.source == :injector and
        match?(%WebhookReceived{status: "completed"}, entry.event)
      end)

  ## Comparison with Direct Adapter Calls

  For simple tests that only need command return values (no injector events),
  calling the adapter directly is simpler:

      {:ok, user_context} = MyAdapter.setup(%{})

      runtime = %PropertyDamage.Runtime{
        inject: fn _event -> :ok end,
        start_poller: fn _opts -> raise "no pollers in a direct call" end
      }

      {:ok, events} = MyAdapter.execute(%CreateUser{name: "alice"}, user_context, runtime)

      assert [%UserCreated{name: "alice"}] = events
      MyAdapter.teardown(user_context)

  The adapter callback is `execute/3`: command, user context, runtime handle.
  The stub handle above suits an adapter that neither injects events nor
  starts pollers; the two functions are the required fields of the struct.

  Use `PropertyDamage.execute/2` when you need the full infrastructure: injector adapters,
  event queue, external() value resolution across commands, etc.
  """
  @spec execute([struct()], keyword()) ::
          {:ok, [PropertyDamage.EventLog.Entry.t()]} | {:error, term()}
  def execute(commands, opts) when is_list(commands) do
    opts = Options.validate_execute!(opts)

    [target] = opts[:targets]
    Options.reject_unsupported_target_keys!([target], [:mocks], "PropertyDamage.execute/2")
    %{adapter: adapter, injectors: injectors, config: config} = target

    # Start event queue for injectors. Its stop is guaranteed by the outer
    # `after` below so that a raise in injector or adapter setup cannot leak it
    # injector/adapter setup therefore lives inside the outer try.
    {:ok, event_queue} = EventQueue.start_link()

    try do
      {set_up, _lines} =
        PropertyDamage.Log.inline(fn ->
          RunServices.setup_injectors(injectors, config, event_queue)
        end)

      case set_up do
        {:ok, injector_contexts} ->
          sequence = Sequence.linear(commands)
          execute_with_injectors(sequence, adapter, config, event_queue, injector_contexts)

        # The injectors set up before the failing one are already torn down.
        {:error, reason} ->
          {:error, Failure.setup_failed(reason)}
      end
    after
      EventQueue.stop(event_queue)
    end
  end

  # Sets the adapter up and runs the sequence once the injectors are up, then
  # tears down the adapter and the injectors.
  #
  # Setup and teardown run in a scope of their own, and each command logs into
  # a sink of its own (`Executor.execute_raw/3`); this call builds no failure
  # report, so every log line is dropped (DR-054).
  defp execute_with_injectors(sequence, adapter, config, event_queue, injector_contexts) do
    {set_up, _lines} = PropertyDamage.Log.inline(fn -> adapter.setup(config) end)

    case set_up do
      {:ok, adapter_context} ->
        context = %{adapter_context: adapter_context, event_queue: event_queue}

        try do
          Executor.execute_raw(sequence, adapter, context)
        after
          # Cleanup. The event queue is stopped by the caller's `after`.
          PropertyDamage.Log.inline(fn ->
            adapter.teardown(adapter_context)
            RunServices.teardown_injectors(injector_contexts)
          end)
        end

      {:error, reason} ->
        # Cleanup injectors on setup failure; the event queue is stopped by the
        # caller's `after`.
        PropertyDamage.Log.inline(fn -> RunServices.teardown_injectors(injector_contexts) end)
        {:error, Failure.setup_failed(reason)}
    end
  end

  # ============================================================================
  # External Values (Server-Generated IDs)
  # ============================================================================

  @doc """
  Mark a field as server-generated (external) in event struct definitions.

  Use `external()` as the default value for fields that will be populated by
  the System Under Test (SUT) during execution, such as auto-generated IDs,
  timestamps, or transaction references.

  ## Basic Usage

      defmodule MyApp.Events.OrderCreated do
        import PropertyDamage, only: [external: 0]

        # id is server-generated, amount comes from the command
        defstruct [:amount, :customer_id, id: external()]
      end

  ## Multiple Externals

  Events can have multiple external fields:

      defmodule MyApp.Events.PaymentProcessed do
        import PropertyDamage, only: [external: 0]

        defstruct [
          :order_id,
          :amount,
          payment_id: external(),
          transaction_id: external()
        ]
      end

  ## Nested Externals

  Externals are supported in nested maps:

      defstruct [
        :amount,
        ids: %{transaction: external(), confirmation: external()}
      ]

  ## Fixed-Length Lists

  Externals are supported in fixed-length lists:

      defstruct [
        :batch_name,
        item_ids: [external(), external(), external()]
      ]

  ## How It Works

  1. In your simulator, return events with external fields unset. `simulate/2`
     returns a bare list of event structs; `id: external()` is implicit:

      def simulate(%CreateOrder{amount: amt}, _state) do
        [%OrderCreated{amount: amt}]
      end

  2. The framework automatically:
     - Detects external markers during simulation
     - Creates internal placeholders to track dependencies (these flow into
       projection state in place of the marker)
     - Resolves placeholders with real values from the SUT

  3. In projections, you receive concrete values at execution time:

      def apply(state, %OrderCreated{id: id, amount: amt}) do
        put_in(state.orders[id], %{amount: amt})  # id is a real value
      end

  4. To make a later command consume a server-generated value, route a
     placeholder out of state in the model's `overrides:` function. During
     generation the projection holds placeholders, which
     `PropertyDamage.Generator.external_from/2` surfaces as a seeded choice:

      # in the model's command list
      {ViewOrder,
       when: fn state -> map_size(state.orders) > 0 end,
       overrides: fn state ->
         %{order_id: PropertyDamage.Generator.external_from(state, path: [:id])}
       end}

     The chosen placeholder resolves to the real id before `ViewOrder` runs.

  ## Limitations

  Variable-length lists where the count isn't known at struct definition
  time are not supported. If you need a variable number of external IDs,
  mark the entire list as `external()` and have the SUT return the complete list.

  ## See Also

  - `PropertyDamage.External` - Implementation details and path detection
  """
  @spec external() :: PropertyDamage.External.t()
  defdelegate external(), to: PropertyDamage.External

  @doc """
  Mark a command field as a client-minted, run-scoped value (DR-034).

  Use inside a command generator to send a value that must be **unique per run
  yet reproducible** — a request UUID or idempotency key sent to a System Under
  Test you cannot reset between runs:

      def generator(overrides) do
        %{
          request_id: StreamData.constant(PropertyDamage.mint_per_run(:uuid)),
          amount: StreamData.integer(1..100)
        }
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end

  The field holds a marker during generation (so the plan stays a pure function
  of the seed and is positionally identical across runs), and resolves at
  execution to a value derived from the run's `run_nonce`/`mint_epoch` and the
  field's coordinates. Hold `(seed, run_number)` and vary the nonce to re-run
  the identical plan with fresh minted values on a shared SUT.

  Contrast with `external/0`, which captures a value the SUT *returns*;
  `mint_per_run` mints a value the client *sends*.

  ## Kinds

  - `:uuid` - an RFC 4122 (version 4) UUID string.
  - `{:hex, n}` - `n` lowercase hex characters.
  - `{module, function}` - escape hatch; `function` receives the derived bytes
    (a binary) and returns the value. Anonymous functions are rejected: markers
    persist inside plans/traces and must survive `binary_to_term`.
  """
  @spec mint_per_run(PropertyDamage.Mint.kind()) :: PropertyDamage.Mint.t()
  defdelegate mint_per_run(kind), to: PropertyDamage.Mint, as: :new

  @doc """
  Audit that a model's generation is a pure function of the seed (DR-037).

  Generation MUST be deterministic in `(seed, model, generation opts)`: all
  nondeterminism (clock, `:rand`, client-minted ids, environment) belongs
  behind an execution-time seam, never in a generator / `when:` / `overrides:` /
  projection. This realizes the model's generated sequence twice at each of N
  seeds and asserts the two are structurally equal, catching impurity at
  dev/CI time before it breaks `seed: N` reproduction and
  `PropertyDamage.RunComparison`'s fingerprint guard.

  Returns `:ok`, or `{:error, %{seed: seed, divergence: divergence}}` for the
  first diverging seed. See `PropertyDamage.Audit` for options and
  `guides/deterministic_generation.md` for the deterministic patterns; `mix
  pd.audit` wraps this for CI gating.
  """
  @spec audit(module(), keyword()) :: PropertyDamage.Audit.result()
  def audit(model, opts \\ []), do: PropertyDamage.Audit.run(model, opts)

  @doc """
  Audit that a model's projection `apply/2` is a pure function of its inputs
  (DR-040).

  Companion to `audit/2`: folds each seed's generated plan through every
  projection twice (using the model's simulator to predict events) and names any
  projection whose two folds disagree — i.e. one that read a clock, a counter,
  or the environment in `apply/2`. Generation-only (no adapter/SUT), the dev/CI
  early warning for the runtime projection-purity check
  (`PropertyDamage.FailureReport.verify_projections/1`). `mix pd.audit` runs it
  alongside the generation audit.

  Returns `:ok`, or `{:error, %{seed: seed, modules: [module()]}}`.
  """
  @spec audit_projections(module(), keyword()) ::
          :ok | {:error, %{seed: integer(), modules: [module()]}}
  def audit_projections(model, opts \\ []),
    do: PropertyDamage.Audit.projection_purity(model, opts)

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PropertyDamage, only: []
    end
  end
end
