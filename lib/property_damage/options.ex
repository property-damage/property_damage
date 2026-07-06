defmodule PropertyDamage.Options do
  @moduledoc false

  # ============================================================================
  # PropertyDamage.run/1 Schema
  # ============================================================================

  @run_schema_definition [
    # Required
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module implementing `PropertyDamage.Model` behaviour."
    ],
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module implementing `PropertyDamage.Adapter` behaviour."
    ],

    # Optional - Basic
    max_commands: [
      type: :pos_integer,
      default: 50,
      doc: "Maximum commands per test sequence."
    ],
    max_runs: [
      type: :pos_integer,
      default: 100,
      doc: "Number of test sequences to run."
    ],
    seed: [
      type: :pos_integer,
      doc: "Random seed for reproducibility. Defaults to random."
    ],
    run_nonce: [
      type: :non_neg_integer,
      doc:
        "64-bit nonce seeding client-minted run-scoped values (DR-034). " <>
          "Defaults to strong random entropy (never the process RNG). Hold " <>
          "(seed, run_number) and vary this to re-run the same plan with fresh " <>
          "minted values on a shared SUT."
    ],
    verbose: [
      type: :boolean,
      default: false,
      doc: "Print progress and configuration."
    ],
    validate: [
      type: :boolean,
      default: true,
      doc: "Run configuration validation before testing."
    ],
    shrink: [
      type: :boolean,
      default: true,
      doc: "Shrink failing sequences to minimal reproduction."
    ],
    coverage: [
      type: :boolean,
      default: false,
      doc: """
      Accumulate the heavier whole-run coverage dimensions
      (command/transition/state) across all generated sequences, attached to the
      success stats as `:coverage` (a `PropertyDamage.Coverage` tracker).
      Per-assertion/invariant coverage (anti-vacuity) is always collected
      regardless of this flag; see `PropertyDamage.assertion_coverage/2`.
      """
    ],
    seed_library: [
      type: {:or, [:boolean, :string]},
      default: false,
      doc: """
      Ephemeral replay working set of recently-failing seeds (DR-023), replayed
      before random exploration:
      - `false` (default) - disabled; no file is read or written.
      - `true` - use the default file `property_damage_seeds.json`.
      - `"path"` - use an explicit file.

      When enabled, library seeds are replayed first; if any still fail,
      exploration is skipped and the run halts with a summary. A new failure
      found during exploration is appended (deduplicated by seed). See
      `PropertyDamage.SeedLibrary`.
      """
    ],
    seed_library_prune_after: [
      type: :pos_integer,
      default: 3,
      doc: """
      Number of consecutive passing replays (`K`) after which a seed is dropped
      from the library. Only meaningful when `seed_library:` is enabled.
      """
    ],

    # Optional - Advanced
    injector_adapters: [
      type: {:list, :atom},
      default: [],
      doc: "List of InjectorAdapter modules for event injection."
    ],
    mock_services: [
      type: {:custom, __MODULE__, :validate_mock_services, []},
      default: [],
      doc: """
      Mock third-party services the SUT calls, as a list where each entry is a
      `PropertyDamage.MockServiceAdapter` module or a `{module, config}` tuple.

      Per run the framework starts a `PropertyDamage.MockServiceRegistry`,
      registers each mock (`init_state/0`) and calls its `setup/1` with the
      entry's config merged with `%{registry: pid, event_queue: pid}`, drives
      `on_command/2` before each command, folds the events mocks push
      (`source: :mock`) into projections after each command, and tears each mock
      down at the end. The registry pid is handed to the adapter on the
      `PropertyDamage.Runtime` handle (`runtime.mock_registry`) so `execute/3`
      can drive `handle_request/2`. See `PropertyDamage.MockServiceAdapter`.
      """
    ],
    external_markers: [
      type: {:list, :atom},
      default: [],
      doc: """
      Additional atoms to treat as external markers.

      This allows domain libraries to mark server-generated fields without
      depending on PropertyDamage:

          # In domain library (no PropertyDamage dependency)
          defstruct [id: :__external__, :amount]

          # In test project
          PropertyDamage.run(model: M, adapter: A, external_markers: [:__external__])

      This run option is the sole source of atom markers; there is no ambient
      app-config channel (DR-032).
      """
    ],
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Configuration passed to `adapter.setup/1`."
    ],
    shrinker_config: [
      type: :any,
      doc: "ShrinkerConfig struct for tuning shrinking behavior."
    ],
    on_failure: [
      type: {:fun, 1},
      doc: "Callback `fn failure_report -> any` called on test failure."
    ],
    on_progress: [
      type: {:fun, 1},
      doc: """
      Callback `fn %PropertyDamage.Progress{} -> any` receiving the unified
      progress projection: ordered `RunUpdate`s during the run and a terminal
      `RunResult`. See `PropertyDamage.Progress` (DR-022).
      """
    ],
    assertion_mode: [
      type: {:in, [:disabled, :halt, :record, :log]},
      default: :halt,
      doc: """
      How to handle assertion failures:
      - `:halt` - Stop on first failure (default)
      - `:disabled` - Skip all assertions
      - `:record` - Record failures but continue
      - `:log` - Log failures as warnings and continue
      """
    ],

    # Nested - Branching
    branching: [
      type: :keyword_list,
      doc: "Options for parallel branch testing (race condition detection).",
      keys: [
        branch_probability: [
          type: :float,
          default: 0.2,
          doc: "Probability of creating a branch point (0.0-1.0)."
        ],
        max_branches: [
          type: :pos_integer,
          default: 3,
          doc: "Maximum number of parallel branches."
        ],
        max_branch_length: [
          type: :pos_integer,
          default: 5,
          doc: "Maximum commands per branch."
        ],
        min_prefix_length: [
          type: :pos_integer,
          default: 3,
          doc: "Minimum commands before branching."
        ]
      ]
    ],

    # Nested - Stutter (Idempotency Testing)
    stutter: [
      type: :keyword_list,
      doc: "Options for idempotency testing (command retry behavior).",
      keys: [
        probability: [
          type: :float,
          default: 0.1,
          doc: "Probability of stuttering each command (0.0-1.0)."
        ],
        max_repeats: [
          type: :pos_integer,
          default: 2,
          doc: "Maximum retry attempts per stuttered command."
        ],
        delay_ms: [
          type: :any,
          doc: "Delay between retries: integer or `{min, max}` tuple."
        ],
        commands: [
          type: :any,
          default: :all,
          doc: "`:all` or list of command modules to stutter."
        ],
        comparison: [
          type: :any,
          default: :strict,
          doc: """
          Event comparison mode:
          - `:strict` - Events must be exactly equal
          - `{:structural, fields}` - Ignore specified fields
          - `{:custom, fun}` - Custom comparison function
          """
        ]
      ]
    ],

    # Nested - Regression
    regression: [
      type: :keyword_list,
      doc: "Options for automatic regression test management.",
      keys: [
        save_failures: [
          type: :string,
          doc: "Directory to save failure files."
        ],
        seed_library: [
          type: :string,
          doc: "Path to seed library JSON file."
        ],
        generate_tests: [
          type: :string,
          doc: "Directory for generated ExUnit test files."
        ],
        tags: [
          type: {:list, :atom},
          default: [:auto_detected],
          doc: "Tags to add to seed library entries."
        ],
        dedup: [
          type: :boolean,
          default: false,
          doc: "Skip if similar failure already exists."
        ],
        dedup_threshold: [
          type: :float,
          default: 0.90,
          doc: "Similarity threshold for deduplication (0.0-1.0)."
        ],
        verbose: [
          type: :boolean,
          default: false,
          doc: "Print regression actions."
        ],
        adapter: [
          type: :atom,
          doc:
            "Adapter module supplying `http_spec/2` for generated regression tests " <>
              "(defaults to the run's adapter via the failure report)."
        ]
      ]
    ]
  ]

  @run_schema NimbleOptions.new!(@run_schema_definition)

  @doc """
  Returns the compiled NimbleOptions schema for `PropertyDamage.run/1`.
  """
  @spec run_schema() :: NimbleOptions.t()
  def run_schema, do: @run_schema

  @doc """
  Returns NimbleOptions-generated documentation for run options.

  Suitable for embedding in moduledocs.
  """
  @spec run_docs() :: String.t()
  def run_docs, do: NimbleOptions.docs(@run_schema)

  @doc """
  Validates options for `PropertyDamage.run/1`.

  Returns validated options with defaults applied, or raises
  `NimbleOptions.ValidationError` on invalid input.
  """
  @spec validate_run!(keyword()) :: keyword()
  def validate_run!(opts) do
    opts
    |> NimbleOptions.validate!(@run_schema)
    |> validate_branching_bounds!()
  end

  # Cross-field check NimbleOptions can't express: branching cannot begin until
  # `min_prefix_length` commands have run, but the prefix is capped by
  # `max_commands`. If min_prefix_length > max_commands the generator can never
  # reach the branch point and prefix generation spins. Fail fast and clearly.
  defp validate_branching_bounds!(opts) do
    with branching when is_list(branching) <- Keyword.get(opts, :branching),
         max_commands when is_integer(max_commands) <- Keyword.get(opts, :max_commands, 50),
         min_prefix when is_integer(min_prefix) <- Keyword.get(branching, :min_prefix_length, 3),
         true <- min_prefix > max_commands do
      raise ArgumentError,
            "Invalid branching options: min_prefix_length (#{min_prefix}) must be <= " <>
              "max_commands (#{max_commands}); otherwise branching can never start and " <>
              "generation would not terminate."
    else
      _ -> opts
    end
  end

  # ============================================================================
  # PropertyDamage.LoadTest.run/1 Schema
  # ============================================================================

  @load_test_schema_definition [
    # Required
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module implementing `PropertyDamage.Model` behaviour."
    ],
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module implementing `PropertyDamage.Adapter` behaviour."
    ],
    run_nonce: [
      type: :non_neg_integer,
      doc:
        "Nonce seeding client-minted run-scoped values (DR-034). One per load " <>
          "test; each worker derives a distinct mint_epoch from its worker id. " <>
          "Defaults to strong random entropy."
    ],
    arrival_rate: [
      type: {:custom, __MODULE__, :validate_arrival_rate, []},
      required: true,
      doc: """
      Target arrival rate. Can be specified as:
      - Integer: arrivals per second (e.g., `100` = 100/sec)
      - Tuple: `{count, {time, unit}}` (e.g., `{2, {15, :milliseconds}}` = 2 every 15ms)
      """
    ],
    duration: [
      type:
        {:custom, __MODULE__, :validate_duration, [[:milliseconds, :seconds, :minutes, :hours]]},
      required: true,
      doc: "Test duration as `{value, unit}` tuple (e.g., `{5, :minutes}`)."
    ],

    # Optional
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Configuration passed to `adapter.setup/1`."
    ],
    arrival_jitter: [
      type: {:custom, __MODULE__, :validate_range, []},
      default: {0, 0},
      doc: "`{min, max}` milliseconds random jitter added to each arrival interval."
    ],
    ramp_up: [
      type: {:custom, __MODULE__, :validate_ramp_strategy, []},
      default: :immediate,
      doc: """
      Strategy for ramping up arrival rate:
      - `:immediate` - Start at full rate
      - `{:linear, duration}` - Linear ramp from 0 to target rate
      - `{:step, count, interval}` - Increase rate in steps
      - `{:exponential, duration}` - Exponential growth curve
      """
    ],
    ramp_down: [
      type: {:custom, __MODULE__, :validate_ramp_strategy, []},
      default: :immediate,
      doc: "Strategy for ramping down arrival rate (same options as `:ramp_up`)."
    ],
    think_time: [
      type: {:custom, __MODULE__, :validate_range, []},
      default: {0, 0},
      doc: "`{min, max}` milliseconds delay between commands within a sequence."
    ],
    metrics_interval: [
      type:
        {:custom, __MODULE__, :validate_duration, [[:milliseconds, :seconds, :minutes, :hours]]},
      default: {1, :seconds},
      doc: "Snapshot cadence: how often a `LoadUpdate` progress value is emitted."
    ],
    on_progress: [
      type: {:fun, 1},
      doc: """
      Callback `fn %PropertyDamage.Progress{} -> any` receiving the unified
      progress projection: a `LoadUpdate` (carrying a metrics snapshot) each
      `metrics_interval`, and a terminal `LoadResult` (carrying the final
      report) at completion. See `PropertyDamage.Progress` (DR-022).
      """
    ],
    assertion_mode: [
      type: {:in, [:disabled, :halt, :record, :log]},
      default: :disabled,
      doc: """
      How to handle assertions during load testing:
      - `:disabled` - Skip all assertions (maximum throughput, default)
      - `:record` - Run assertions and record failures in metrics
      - `:log` - Run assertions and log failures as warnings
      - `:halt` - Stop on first failure
      """
    ]
  ]

  @load_test_schema NimbleOptions.new!(@load_test_schema_definition)

  @doc """
  Returns the compiled NimbleOptions schema for `PropertyDamage.LoadTest.run/1`.
  """
  @spec load_test_schema() :: NimbleOptions.t()
  def load_test_schema, do: @load_test_schema

  @doc """
  Returns NimbleOptions-generated documentation for load test options.

  Suitable for embedding in moduledocs.
  """
  @spec load_test_docs() :: String.t()
  def load_test_docs, do: NimbleOptions.docs(@load_test_schema)

  @doc """
  Validates options for `PropertyDamage.LoadTest.run/1`.

  Returns validated options with defaults applied, or raises
  `NimbleOptions.ValidationError` on invalid input.
  """
  @spec validate_load_test!(keyword()) :: keyword()
  def validate_load_test!(opts) do
    NimbleOptions.validate!(opts, @load_test_schema)
  end

  # ============================================================================
  # PropertyDamage.Replay.run/2 and start/2 Schema
  # ============================================================================

  @replay_schema_definition [
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Override adapter configuration."
    ],
    stop_on_failure: [
      type: :boolean,
      default: true,
      doc: "Stop replay at first failure."
    ],
    include_projections: [
      type: :boolean,
      default: true,
      doc: "Include projection states in step results."
    ]
  ]

  @replay_schema NimbleOptions.new!(@replay_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Replay.run/2` and `start/2`.
  """
  @spec validate_replay!(keyword()) :: keyword()
  def validate_replay!(opts) do
    NimbleOptions.validate!(opts, @replay_schema)
  end

  # ============================================================================
  # PropertyDamage.Analysis.generate_test/2 Schema
  # ============================================================================

  @generate_test_schema_definition [
    format: [
      type: {:in, [:exunit, :script, :markdown]},
      default: :exunit,
      doc: "Output format: `:exunit`, `:script`, or `:markdown`."
    ],
    module_name: [
      type: :string,
      default: "ReproductionTest",
      doc: "Module name for ExUnit tests."
    ]
  ]

  @generate_test_schema NimbleOptions.new!(@generate_test_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Analysis.generate_test/2`.
  """
  @spec validate_generate_test!(keyword()) :: keyword()
  def validate_generate_test!(opts) do
    NimbleOptions.validate!(opts, @generate_test_schema)
  end

  # ============================================================================
  # PropertyDamage.Mutation.run/1 Schema
  # ============================================================================

  @mutation_schema_definition [
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module implementing `PropertyDamage.Model` behaviour."
    ],
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module implementing `PropertyDamage.Adapter` behaviour."
    ],
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Configuration passed to `adapter.setup/1`."
    ],
    operators: [
      type: {:list, {:in, [:value, :omission, :status, :event, :boundary]}},
      default: [:value, :omission, :status, :event, :boundary],
      doc: "List of mutation operators to use."
    ],
    mutations_per_command: [
      type: :pos_integer,
      default: 5,
      doc: "Maximum mutations per command type."
    ],
    max_runs: [
      type: :pos_integer,
      default: 10,
      doc: "Property test runs per mutation."
    ],
    target_score: [
      type: :float,
      default: 0.80,
      doc: "Target mutation score (0.0-1.0)."
    ],
    timeout_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Timeout per mutation test in milliseconds."
    ],
    verbose: [
      type: :boolean,
      default: false,
      doc: "Print progress."
    ],
    on_progress: [
      type: {:fun, 1},
      doc: "Callback for progress updates."
    ]
  ]

  @mutation_schema NimbleOptions.new!(@mutation_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Mutation.run/1`.
  """
  @spec validate_mutation!(keyword()) :: keyword()
  def validate_mutation!(opts) do
    NimbleOptions.validate!(opts, @mutation_schema)
  end

  # ============================================================================
  # PropertyDamage.Differential.run/1 Schema
  # ============================================================================

  @differential_schema_definition [
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module implementing `PropertyDamage.Model` behaviour."
    ],
    run_nonce: [
      type: :non_neg_integer,
      doc:
        "Nonce seeding client-minted run-scoped values (DR-034), shared by all " <>
          "targets so each receives byte-identical minted requests. Defaults to " <>
          "strong random entropy."
    ],
    targets: [
      type: {:custom, __MODULE__, :validate_non_empty_list, []},
      required: true,
      doc: "List of target specifications: `{AdapterModule}` or `{AdapterModule, opts}`."
    ],
    compare: [
      type: {:in, [:correctness, :performance, :both]},
      required: true,
      doc: "Comparison mode: `:correctness`, `:performance`, or `:both`."
    ],
    max_commands: [
      type: :pos_integer,
      default: 50,
      doc: "Maximum commands per sequence."
    ],
    max_runs: [
      type: :pos_integer,
      default: 100,
      doc: "Number of test sequences to run."
    ],
    seed: [
      type: :pos_integer,
      doc: "Random seed for reproducibility."
    ],
    execution: [
      type: {:in, [:interleaved, :sequential]},
      doc: "Execution mode: `:interleaved` or `:sequential`."
    ],
    equivalence: [
      type: :any,
      default: :exact,
      doc: "Equivalence strategy: `:exact`, `:structural`, or custom function."
    ],
    baseline: [
      type: :string,
      doc: "Path to baseline file for comparison."
    ],
    export_to: [
      type: :string,
      doc: "Path to export results for future baseline."
    ],
    metrics: [
      type: {:list, {:in, [:latency, :throughput]}},
      default: [:latency, :throughput],
      doc: "Performance metrics to collect."
    ],
    percentiles: [
      type: {:list, :pos_integer},
      default: [50, 95, 99],
      doc: "Latency percentiles to calculate."
    ],
    warmup_runs: [
      type: :non_neg_integer,
      default: 0,
      doc: "Runs to discard before measuring."
    ],
    verbose: [
      type: :boolean,
      default: false,
      doc: "Print progress."
    ],
    on_progress: [
      type: {:fun, 1},
      doc: "Progress consumer (DR-022); called with a `%PropertyDamage.Progress{}`."
    ],
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Default adapter configuration."
    ]
  ]

  @differential_schema NimbleOptions.new!(@differential_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Differential.run/1`.
  """
  @spec validate_differential!(keyword()) :: keyword()
  def validate_differential!(opts) do
    NimbleOptions.validate!(opts, @differential_schema)
  end

  # ============================================================================
  # PropertyDamage.Export Schemas
  # ============================================================================

  @export_exunit_schema_definition [
    model: [
      type: :atom,
      doc: "Model module (defaults to report.model)."
    ],
    adapter: [
      type: :atom,
      doc: "Adapter module (defaults to report.adapter)."
    ],
    module_name: [
      type: {:or, [:string, :atom]},
      doc: "Module name for the test (string or atom)."
    ],
    test_name: [
      type: :string,
      doc: "Custom test name."
    ],
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Adapter configuration map."
    ],
    expect_fixed: [
      type: :boolean,
      default: false,
      doc: "If true, expect the test to pass."
    ]
  ]

  @export_exunit_schema NimbleOptions.new!(@export_exunit_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Export.to_exunit/2`.
  """
  @spec validate_export_exunit!(keyword()) :: keyword()
  def validate_export_exunit!(opts) do
    NimbleOptions.validate!(opts, @export_exunit_schema)
  end

  @export_script_schema_definition [
    base_url: [
      type: :string,
      required: true,
      doc: "Base URL for HTTP calls."
    ],
    adapter: [
      type: :atom,
      doc: "Adapter module for HTTPSpec mapping."
    ],
    env_var: [
      type: :string,
      default: "BASE_URL",
      doc: "Environment variable name for base URL."
    ],
    verbose: [
      type: :boolean,
      default: true,
      doc: "Include extra comments."
    ]
  ]

  @export_script_schema NimbleOptions.new!(@export_script_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Export.to_script/3`.
  """
  @spec validate_export_script!(keyword()) :: keyword()
  def validate_export_script!(opts) do
    NimbleOptions.validate!(opts, @export_script_schema)
  end

  @export_livebook_schema_definition [
    base_url: [
      type: :string,
      required: true,
      doc: "Base URL for HTTP calls."
    ],
    adapter: [
      type: :atom,
      doc: "Adapter module for HTTPSpec mapping."
    ],
    title: [
      type: :string,
      doc: "Custom notebook title."
    ],
    include_exploration: [
      type: :boolean,
      default: true,
      doc: "Include exploration section."
    ],
    include_state_tracking: [
      type: :boolean,
      default: true,
      doc: "Track model state."
    ]
  ]

  @export_livebook_schema NimbleOptions.new!(@export_livebook_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Export.to_livebook/2`.
  """
  @spec validate_export_livebook!(keyword()) :: keyword()
  def validate_export_livebook!(opts) do
    NimbleOptions.validate!(opts, @export_livebook_schema)
  end

  # ============================================================================
  # PropertyDamage.execute/2 Schema
  # ============================================================================

  @execute_schema_definition [
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module for executing commands."
    ],
    injector_adapters: [
      type: {:list, :atom},
      default: [],
      doc: "List of injector adapter modules."
    ],
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Configuration passed to `adapter.setup/1`."
    ]
  ]

  @execute_schema NimbleOptions.new!(@execute_schema_definition)

  @doc """
  Returns the compiled NimbleOptions schema for `PropertyDamage.execute/2`.
  """
  @spec execute_schema() :: NimbleOptions.t()
  def execute_schema, do: @execute_schema

  @doc """
  Returns NimbleOptions-generated documentation for execute options.
  """
  @spec execute_docs() :: String.t()
  def execute_docs, do: NimbleOptions.docs(@execute_schema)

  @doc """
  Validates options for `PropertyDamage.execute/2`.

  Returns validated options with defaults applied, or raises
  `NimbleOptions.ValidationError` on invalid input.
  """
  @spec validate_execute!(keyword()) :: keyword()
  def validate_execute!(opts) do
    NimbleOptions.validate!(opts, @execute_schema)
  end

  # ============================================================================
  # PropertyDamage.Integration Schemas
  # ============================================================================

  @integration_run_schema_definition [
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module implementing `PropertyDamage.Model` behaviour."
    ],
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module implementing `PropertyDamage.Adapter` behaviour."
    ],
    adapter_config: [
      type: :map,
      required: true,
      doc: "Configuration passed to `adapter.setup/1`."
    ],
    max_runs: [
      type: :pos_integer,
      default: 100,
      doc: "Number of test runs."
    ],
    max_commands: [
      type: :pos_integer,
      default: 50,
      doc: "Max commands per run."
    ],
    verbose: [
      type: :boolean,
      default: true,
      doc: "Print progress."
    ],
    stop_on_failure: [
      type: :boolean,
      default: false,
      doc: "Stop on first failure."
    ],
    save_failures: [
      type: :string,
      doc: "Directory to save failure files."
    ],
    reset_fn: [
      type: {:fun, 0},
      doc: "Zero-arity function to reset service state between runs."
    ],
    health_check: [
      type: :any,
      doc: "Health check configuration (keyword list or map); see `health_check/1`."
    ],
    report: [
      type: :any,
      doc: "Report configuration (keyword list or map); see `generate_report/2`."
    ]
  ]

  @integration_run_schema NimbleOptions.new!(@integration_run_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Integration.run/1`.
  """
  @spec validate_integration_run!(keyword()) :: keyword()
  def validate_integration_run!(opts) do
    NimbleOptions.validate!(opts, @integration_run_schema)
  end

  @integration_hunt_bugs_schema_definition [
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module implementing `PropertyDamage.Model` behaviour."
    ],
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module implementing `PropertyDamage.Adapter` behaviour."
    ],
    adapter_config: [
      type: :map,
      required: true,
      doc: "Configuration passed to `adapter.setup/1`."
    ],
    stop_after: [
      type: :pos_integer,
      default: 10,
      doc: "Stop after finding this many unique bugs."
    ],
    max_runs: [
      type: {:or, [:pos_integer, {:in, [:unlimited]}]},
      default: :unlimited,
      doc: "Maximum runs before giving up, or `:unlimited`."
    ],
    save_to: [
      type: :string,
      doc: "Directory to save discovered bugs."
    ],
    verbose: [
      type: :boolean,
      default: true,
      doc: "Print progress."
    ]
  ]

  @integration_hunt_bugs_schema NimbleOptions.new!(@integration_hunt_bugs_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Integration.hunt_bugs/1`.
  """
  @spec validate_integration_hunt_bugs!(keyword()) :: keyword()
  def validate_integration_hunt_bugs!(opts) do
    NimbleOptions.validate!(opts, @integration_hunt_bugs_schema)
  end

  @integration_health_check_schema_definition [
    url: [
      type: :string,
      required: true,
      doc: "Health check URL."
    ],
    timeout_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Total timeout in milliseconds."
    ],
    retries: [
      type: :non_neg_integer,
      default: 30,
      doc: "Number of retries."
    ],
    interval_ms: [
      type: :pos_integer,
      default: 1000,
      doc: "Interval between retries in milliseconds."
    ]
  ]

  @integration_health_check_schema NimbleOptions.new!(@integration_health_check_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Integration.health_check/1`.
  """
  @spec validate_integration_health_check!(keyword()) :: keyword()
  def validate_integration_health_check!(opts) do
    NimbleOptions.validate!(opts, @integration_health_check_schema)
  end

  # ============================================================================
  # PropertyDamage.Audit.run/2 Schema (DR-037)
  # ============================================================================

  @audit_schema_definition [
    seeds: [
      type: {:or, [:pos_integer, {:list, :integer}]},
      default: 100,
      doc: "Seed count (audits `0..N-1`) or an explicit list of seeds."
    ],
    max_commands: [
      type: :pos_integer,
      doc: "Max commands per generated sequence."
    ],
    branching: [
      type: :keyword_list,
      doc: "Branching generation options (see `PropertyDamage.run/1`)."
    ],
    external_markers: [
      type: {:list, :atom},
      doc: "Additional atoms to treat as external markers."
    ]
  ]

  @audit_schema NimbleOptions.new!(@audit_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Audit.run/2`.
  """
  @spec validate_audit!(keyword()) :: keyword()
  def validate_audit!(opts) do
    NimbleOptions.validate!(opts, @audit_schema)
  end

  # ============================================================================
  # PropertyDamage.RunComparison Schemas (DR-035)
  # ============================================================================

  @run_comparison_compare_schema_definition [
    event_identity: [
      type: {:fun, 1},
      doc: "`(event -> term())` overriding the default struct-module identity."
    ]
  ]

  @run_comparison_compare_schema NimbleOptions.new!(@run_comparison_compare_schema_definition)

  @doc """
  Validates options for `PropertyDamage.RunComparison.compare/2`.
  """
  @spec validate_run_comparison_compare!(keyword()) :: keyword()
  def validate_run_comparison_compare!(opts) do
    NimbleOptions.validate!(opts, @run_comparison_compare_schema)
  end

  @run_comparison_investigate_schema_definition [
    runs: [
      type: :pos_integer,
      default: 5,
      doc: "Number of times to capture the plan."
    ],
    event_identity: [
      type: {:fun, 1},
      doc: "`(event -> term())` forwarded to `compare/2`."
    ],
    capture: [
      type: :keyword_list,
      required: true,
      doc: """
      Options forwarded to `PropertyDamage.RunTrace.capture/1` (requires
      `:model`, `:adapter`, `:seed`). Passed through rather than duplicated
      here so `RunTrace`'s surface stays single-sourced; a fresh `:run_nonce`
      is injected per capture.
      """
    ]
  ]

  @run_comparison_investigate_schema NimbleOptions.new!(
                                       @run_comparison_investigate_schema_definition
                                     )

  @doc """
  Validates options for `PropertyDamage.RunComparison.investigate/1`.
  """
  @spec validate_run_comparison_investigate!(keyword()) :: keyword()
  def validate_run_comparison_investigate!(opts) do
    NimbleOptions.validate!(opts, @run_comparison_investigate_schema)
  end

  @run_comparison_scan_schema_definition [
    seeds: [
      type: {:list, :integer},
      required: true,
      doc: "The seeds to scan."
    ],
    runs: [
      type: :pos_integer,
      default: 5,
      doc: "Number of captures per seed."
    ],
    event_identity: [
      type: {:fun, 1},
      doc: "`(event -> term())` forwarded to `compare/2`."
    ],
    capture: [
      type: :keyword_list,
      required: true,
      doc: """
      Options forwarded to `PropertyDamage.RunTrace.capture/1` (requires
      `:model` and `:adapter`; `:seed` is supplied per scanned seed). A fresh
      `:run_nonce` is injected per capture.
      """
    ]
  ]

  @run_comparison_scan_schema NimbleOptions.new!(@run_comparison_scan_schema_definition)

  @doc """
  Validates options for `PropertyDamage.RunComparison.scan/1`.
  """
  @spec validate_run_comparison_scan!(keyword()) :: keyword()
  def validate_run_comparison_scan!(opts) do
    NimbleOptions.validate!(opts, @run_comparison_scan_schema)
  end

  # ============================================================================
  # PropertyDamage.Regression Schemas
  # ============================================================================

  # Umbrella opts shared by handler/1, handle_failure/2, check_duplicate/2 and
  # process_batch/2 — they all consume from the same regression_opts bag.
  @regression_opts_schema_definition [
    save_failures: [
      type: :string,
      doc: "Directory to save failure files (also the dedup comparison source)."
    ],
    seed_library: [
      type: :string,
      doc: "Path to the seed library JSON file."
    ],
    generate_tests: [
      type: :string,
      doc: "Directory for generated ExUnit regression tests."
    ],
    tags: [
      type: {:list, :atom},
      default: [:auto_detected],
      doc: "Tags to add to seed library entries."
    ],
    description: [
      type: :string,
      doc: "Optional description for the seed library entry."
    ],
    dedup: [
      type: :boolean,
      default: false,
      doc: "Skip if a similar failure already exists."
    ],
    dedup_threshold: [
      type: :float,
      default: 0.90,
      doc: "Similarity threshold for deduplication (0.0-1.0)."
    ],
    dedup_source: [
      type: {:in, [:failures]},
      default: :failures,
      doc: "Source of comparison material for dedup (saved failure files only)."
    ],
    verbose: [
      type: :boolean,
      default: false,
      doc: "Print regression actions."
    ],
    adapter: [
      type: :atom,
      doc: "Adapter module for generated test HTTP-spec mapping."
    ],
    adapter_config: [
      type: :any,
      doc: "Adapter config embedded in the generated regression test's run opts."
    ]
  ]

  @regression_opts_schema NimbleOptions.new!(@regression_opts_schema_definition)

  @doc """
  Validates the umbrella options for `PropertyDamage.Regression` handlers
  (`handler/1`, `handle_failure/2`, `check_duplicate/2`, `process_batch/2`).
  """
  @spec validate_regression_opts!(keyword()) :: keyword()
  def validate_regression_opts!(opts) do
    NimbleOptions.validate!(opts, @regression_opts_schema)
  end

  @regression_save_failure_schema_definition [
    filename: [
      type: :string,
      doc: "Explicit filename; defaults to an auto-generated name."
    ],
    overwrite: [
      type: :boolean,
      default: false,
      doc: "Overwrite an existing file at the target path."
    ]
  ]

  @regression_save_failure_schema NimbleOptions.new!(@regression_save_failure_schema_definition)

  @doc """
  Validates options for `PropertyDamage.Regression.save_failure/2` (forwarded to
  `PropertyDamage.Persistence.save/3`).
  """
  @spec validate_regression_save_failure!(keyword()) :: keyword()
  def validate_regression_save_failure!(opts) do
    NimbleOptions.validate!(opts, @regression_save_failure_schema)
  end

  @regression_add_to_library_schema_definition [
    tags: [
      type: {:list, :atom},
      default: [:auto_detected],
      doc: "Tags to add to the entry."
    ],
    description: [
      type: :string,
      doc: "Optional description for the entry."
    ]
  ]

  @regression_add_to_library_schema NimbleOptions.new!(
                                      @regression_add_to_library_schema_definition
                                    )

  @doc """
  Validates options for `PropertyDamage.Regression.add_to_library/2`.
  """
  @spec validate_regression_add_to_library!(keyword()) :: keyword()
  def validate_regression_add_to_library!(opts) do
    NimbleOptions.validate!(opts, @regression_add_to_library_schema)
  end

  # ============================================================================
  # Custom Type Validators
  # ============================================================================

  @valid_duration_units [:milliseconds, :seconds, :minutes, :hours]

  @doc false
  # Each mock service is a module or a {module, config-map} tuple. Config
  # defaults to %{} and is later merged with the framework's :registry /
  # :event_queue before reaching the mock's setup/1.
  def validate_mock_services(value) when is_list(value) do
    normalized =
      Enum.map(value, fn
        module when is_atom(module) and module != nil ->
          {module, %{}}

        {module, config} when is_atom(module) and module != nil and is_map(config) ->
          {module, config}

        other ->
          throw({:invalid_mock_service, other})
      end)

    {:ok, normalized}
  catch
    {:invalid_mock_service, other} ->
      {:error,
       "expected each mock service to be a module or {module, config_map} tuple, " <>
         "got: #{inspect(other)}"}
  end

  def validate_mock_services(value) do
    {:error, "expected a list of mock services, got: #{inspect(value)}"}
  end

  @doc false
  def validate_module(value) when is_atom(value) and value != nil do
    {:ok, value}
  end

  def validate_module(nil) do
    {:error, "expected a module (atom), got: nil"}
  end

  def validate_module(value) do
    {:error, "expected a module (atom), got: #{inspect(value)}"}
  end

  @doc false
  def validate_duration({value, unit}, valid_units)
      when is_integer(value) and value > 0 and is_list(valid_units) do
    if unit in valid_units do
      {:ok, {value, unit}}
    else
      {:error,
       "expected a duration tuple like {5, :minutes}, got: {#{value}, #{inspect(unit)}}. " <>
         "Valid units: #{inspect(valid_units)}"}
    end
  end

  def validate_duration(value, valid_units) when is_list(valid_units) do
    {:error,
     "expected a duration tuple like {5, :minutes}, got: #{inspect(value)}. " <>
       "Valid units: #{inspect(valid_units)}"}
  end

  @doc false
  def validate_ramp_strategy(:immediate), do: {:ok, :immediate}

  def validate_ramp_strategy({:linear, duration}) do
    case validate_duration(duration, @valid_duration_units) do
      {:ok, d} -> {:ok, {:linear, d}}
      {:error, _} = err -> err
    end
  end

  def validate_ramp_strategy({:step, count, interval})
      when is_integer(count) and count > 0 do
    case validate_duration(interval, @valid_duration_units) do
      {:ok, i} -> {:ok, {:step, count, i}}
      {:error, _} = err -> err
    end
  end

  def validate_ramp_strategy({:exponential, duration}) do
    case validate_duration(duration, @valid_duration_units) do
      {:ok, d} -> {:ok, {:exponential, d}}
      {:error, _} = err -> err
    end
  end

  def validate_ramp_strategy(value) do
    {:error,
     "expected a ramp strategy (:immediate, {:linear, duration}, {:step, n, interval}, " <>
       "or {:exponential, duration}), got: #{inspect(value)}"}
  end

  @doc false
  def validate_range({min, max})
      when is_integer(min) and is_integer(max) and min >= 0 and max >= min do
    {:ok, {min, max}}
  end

  def validate_range(value) do
    {:error,
     "expected a range tuple like {min, max} where min >= 0 and max >= min, " <>
       "got: #{inspect(value)}"}
  end

  @doc false
  def validate_non_empty_list([]) do
    {:error, "expected a non-empty list, got: []"}
  end

  def validate_non_empty_list(value) when is_list(value) do
    {:ok, value}
  end

  def validate_non_empty_list(value) do
    {:error, "expected a non-empty list, got: #{inspect(value)}"}
  end

  @doc false
  # Shorthand: integer = arrivals per second
  def validate_arrival_rate(rate) when is_integer(rate) and rate > 0 do
    {:ok, {rate, {1, :seconds}}}
  end

  # Full form: {count, {time, unit}}
  def validate_arrival_rate({count, {time, unit}})
      when is_integer(count) and count > 0 and is_integer(time) and time > 0 do
    if unit in @valid_duration_units do
      {:ok, {count, {time, unit}}}
    else
      {:error,
       "invalid time unit in arrival_rate: #{inspect(unit)}. " <>
         "Valid units: #{inspect(@valid_duration_units)}"}
    end
  end

  def validate_arrival_rate(value) do
    {:error,
     "expected arrival_rate as integer (arrivals per second, e.g., 100) or " <>
       "tuple {count, {time, unit}} (e.g., {2, {15, :milliseconds}}), got: #{inspect(value)}"}
  end

  @doc """
  Converts a validated arrival rate to interval in milliseconds.

  ## Examples

      iex> arrival_rate_to_interval_ms({100, {1, :seconds}})
      10.0

      iex> arrival_rate_to_interval_ms({2, {15, :milliseconds}})
      7.5
  """
  @spec arrival_rate_to_interval_ms({pos_integer(), {pos_integer(), atom()}}) :: float()
  def arrival_rate_to_interval_ms({count, {time, unit}}) do
    total_ms = duration_to_ms({time, unit})
    total_ms / count
  end

  @doc """
  Converts a duration tuple to milliseconds.
  """
  @spec duration_to_ms({pos_integer(), atom()}) :: non_neg_integer()
  def duration_to_ms({value, :milliseconds}), do: value
  def duration_to_ms({value, :seconds}), do: value * 1_000
  def duration_to_ms({value, :minutes}), do: value * 60_000
  def duration_to_ms({value, :hours}), do: value * 3_600_000
end
