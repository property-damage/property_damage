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
    concurrent_users: [
      type: :pos_integer,
      required: true,
      doc: "Target number of concurrent user sessions."
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
    ramp_up: [
      type: {:custom, __MODULE__, :validate_ramp_strategy, []},
      default: :immediate,
      doc: """
      Strategy for ramping up load:
      - `:immediate` - All users start at once
      - `{:linear, duration}` - Gradual linear ramp
      - `{:step, count, interval}` - Add users in steps
      - `{:exponential, duration}` - Exponential growth curve
      """
    ],
    ramp_down: [
      type: {:custom, __MODULE__, :validate_ramp_strategy, []},
      default: :immediate,
      doc: "Strategy for ramping down load (same options as `:ramp_up`)."
    ],
    commands_per_session: [
      type: {:custom, __MODULE__, :validate_range, []},
      default: {10, 50},
      doc: "`{min, max}` commands per sequence."
    ],
    think_time: [
      type: {:custom, __MODULE__, :validate_range, []},
      default: {0, 0},
      doc: "`{min, max}` milliseconds delay between commands."
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
end
