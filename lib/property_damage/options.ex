defmodule PropertyDamage.Options do
  @moduledoc """
  NimbleOptions schemas for PropertyDamage configuration.

  This module provides compile-time validated schemas for all public APIs.
  It enables better error messages, auto-generated documentation, and
  consistent option handling across the framework.

  ## Usage

  The schemas are used internally by `PropertyDamage.run/1` and
  `PropertyDamage.LoadTest.run/1`. Users don't need to interact with
  this module directly.

  ## Generated Documentation

  Use `run_docs/0` and `load_test_docs/0` to get NimbleOptions-generated
  documentation suitable for embedding in moduledocs.
  """

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

    # Optional - Advanced
    injector_adapters: [
      type: {:list, :atom},
      default: [],
      doc: "List of InjectorAdapter modules for event injection."
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

      These markers are combined with any markers configured in app config
      via `config :property_damage, external_markers: [...]`.
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
    NimbleOptions.validate!(opts, @run_schema)
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
      doc: "Metrics callback interval."
    ],
    on_metrics: [
      type: {:fun, 1},
      doc: "Callback receiving metrics snapshot each interval."
    ],
    on_complete: [
      type: {:fun, 1},
      doc: "Callback receiving final report when test completes."
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
    ],
    include_setup: [
      type: :boolean,
      default: true,
      doc: "Include model/adapter setup code."
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
  # PropertyDamage.GuidedRunner.run/1 Schema
  # ============================================================================

  @guided_runner_schema_definition [
    model: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Model module (must implement TargetedGeneration)."
    ],
    adapter: [
      type: {:custom, __MODULE__, :validate_module, []},
      required: true,
      doc: "Adapter module implementing `PropertyDamage.Adapter` behaviour."
    ],
    generations: [
      type: :pos_integer,
      default: 10,
      doc: "Number of evolutionary generations."
    ],
    population_size: [
      type: :pos_integer,
      default: 20,
      doc: "Seeds per generation."
    ],
    elite_count: [
      type: :pos_integer,
      default: 2,
      doc: "Top seeds to preserve unchanged."
    ],
    mutation_rate: [
      type: :float,
      default: 0.3,
      doc: "Probability of seed mutation (0.0-1.0)."
    ],
    crossover_rate: [
      type: :float,
      default: 0.5,
      doc: "Probability of seed crossover (0.0-1.0)."
    ],
    max_commands: [
      type: :pos_integer,
      default: 50,
      doc: "Commands per sequence."
    ],
    max_runs_per_seed: [
      type: :pos_integer,
      default: 1,
      doc: "Test runs per seed."
    ],
    initial_seeds: [
      type: {:list, :pos_integer},
      doc: "Starting seed list (default: random)."
    ],
    verbose: [
      type: :boolean,
      default: false,
      doc: "Print progress."
    ],
    adapter_config: [
      type: :map,
      default: %{},
      doc: "Configuration passed to `adapter.setup/1`."
    ]
  ]

  @guided_runner_schema NimbleOptions.new!(@guided_runner_schema_definition)

  @doc """
  Validates options for `PropertyDamage.GuidedRunner.run/1`.
  """
  @spec validate_guided_runner!(keyword()) :: keyword()
  def validate_guided_runner!(opts) do
    NimbleOptions.validate!(opts, @guided_runner_schema)
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
    ],
    refs: [
      type: :map,
      default: %{},
      doc: "Initial ref resolution map."
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
  # Custom Type Validators
  # ============================================================================

  @valid_duration_units [:milliseconds, :seconds, :minutes, :hours]

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
