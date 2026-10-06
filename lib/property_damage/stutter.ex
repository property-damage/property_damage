defmodule PropertyDamage.Stutter.Config do
  @moduledoc """
  Configuration for stutter testing.
  """

  @type t :: %__MODULE__{
          probability: float(),
          max_repeats: pos_integer(),
          delay_ms: {non_neg_integer(), non_neg_integer()} | non_neg_integer(),
          commands: :all | [module()],
          using: PropertyDamage.Equivalence.predicate(),
          enabled: boolean()
        }

  defstruct [
    :probability,
    :max_repeats,
    :delay_ms,
    :commands,
    :enabled,
    using: &Kernel.==/2
  ]
end

defmodule PropertyDamage.Stutter.Violation do
  @moduledoc """
  Represents an idempotency violation detected during stutter testing.

  `mismatch` is the exception describing how a retry's events differ from
  the original events: by default a `PropertyDamage.ComparisonMismatch` whose
  `left` holds the original events and `right` the retry's.
  """

  @type attempt :: %{
          attempt: pos_integer(),
          events: [struct()],
          is_retry: boolean()
        }

  @type t :: %__MODULE__{
          command: struct(),
          command_index: non_neg_integer(),
          attempts: [attempt()],
          mismatch: Exception.t()
        }

  defstruct [
    :command,
    :command_index,
    :attempts,
    :mismatch
  ]

  @doc """
  Format violation for display.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = violation) do
    attempts_str =
      violation.attempts
      |> Enum.map_join("\n", fn attempt ->
        events_str =
          attempt.events
          |> Enum.map_join(", ", &inspect(&1.__struct__))

        "  Attempt #{attempt.attempt}: [#{events_str}]"
      end)

    """
    Idempotency violation at command index #{violation.command_index}
    Command: #{inspect(violation.command.__struct__)}
    #{attempts_str}
    """
  end
end

defmodule PropertyDamage.Stutter do
  @moduledoc """
  Stutter testing for idempotency verification.

  Stutter testing automatically retries commands to verify that the SUT
  behaves idempotently - that retrying a command produces the same result.

  ## How It Works

  When stutter testing is enabled, some commands are executed multiple times:

  1. First execution: Events applied to projections normally
  2. Retry executions: Events captured but NOT applied to projections
  3. Framework compares retry events to first execution
  4. Mismatch = idempotency violation

  This approach tests SUT idempotency without requiring idempotent projections.

  ## Configuration

      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        stutter: [
          probability: 0.1,      # 10% of commands stuttered
          max_repeats: 2,        # Up to 2 retries (3 total executions)
          delay_ms: {0, 100},    # Random delay between retries
          commands: :all,        # Or list of specific command modules
          using: &==/2           # fn original_events, retry_events -> ... end
        ]
      )

  ## Command Configuration

  Commands tune idempotency testing through their `command_spec/1`:

  - `idempotent: false` - Exclude the command from stutter testing (default: `true`)

  plus the per-instance `idempotency_key/1` callback, which returns the idempotency
  key passed to the adapter for each request.

  ## Comparing a retry

  A retry agrees with the original when the `using:` predicate accepts it,
  called `using.(original_events, retry_events)` with the contract of
  `@compare`'s `using:` (see `PropertyDamage.Equivalence`): it returns
  `:match` or `true` to agree, and `false`, `{:mismatch, "text"}` or
  `{:mismatch, exception}` otherwise. Without `using:`, the events must be
  equal under `==/2`.
  """

  alias PropertyDamage.Stutter.Config

  @doc """
  Default stutter configuration.
  """
  @spec default_config() :: Config.t()
  def default_config do
    %Config{
      probability: 0.1,
      max_repeats: 2,
      delay_ms: {0, 100},
      commands: :all,
      using: &Kernel.==/2,
      enabled: true
    }
  end

  @doc """
  Parse stutter configuration from options.

  Accepts a keyword list (the `run/1` `:stutter` option shape), a map, or
  `false`/`nil` to disable.
  """
  @spec parse_config(keyword() | map() | false | nil) :: Config.t() | nil
  def parse_config(nil), do: nil
  def parse_config(false), do: nil

  # The run/1 `:stutter` option validates as a keyword list; normalize to the
  # map path so both the documented keyword-list and map shapes work.
  def parse_config(opts) when is_list(opts), do: parse_config(Map.new(opts))

  def parse_config(opts) when is_map(opts) do
    %Config{
      probability: Map.get(opts, :probability, 0.1),
      max_repeats: Map.get(opts, :max_repeats, 2),
      delay_ms: Map.get(opts, :delay_ms, {0, 100}),
      commands: Map.get(opts, :commands, :all),
      using: Map.get(opts, :using) || (&Kernel.==/2),
      enabled: true
    }
  end

  @typedoc """
  An explicit `:rand` generator state (DR-029).

  Stutter draws thread this term instead of reading the process-global RNG: the
  executor derives one per command from `{rng_seed, command_index}`, so a
  command's stutter decisions depend only on the run seed and the command's
  index, not on draws consumed by earlier commands or earlier runs.
  """
  @type rng :: :rand.state()

  @doc """
  Determine if a command should be stuttered based on configuration.

  Draws from the explicit `rng` (DR-029) rather than the process-global `:rand`,
  returning `{decision, rng'}` so the caller threads the advanced state into the
  subsequent `retry_count/2` / `retry_delay_ms/2` draws. Determinism is
  self-consistent: the same `rng` reproduces the same decision. The same applies
  to `retry_count/2` and `retry_delay_ms/2`.
  """
  @spec should_stutter?(struct(), Config.t() | nil, rng(), map() | nil) :: {boolean(), rng()}
  def should_stutter?(command, config, rng, spec \\ nil)
  def should_stutter?(_command, nil, rng, _spec), do: {false, rng}
  def should_stutter?(_command, %Config{enabled: false}, rng, _spec), do: {false, rng}

  def should_stutter?(command, %Config{} = config, rng, spec) do
    command_module = command.__struct__

    # Check if command is in the allowed list
    command_allowed =
      case config.commands do
        :all -> true
        modules when is_list(modules) -> command_module in modules
      end

    # Idempotency eligibility comes from the resolved command spec (DR-028).
    command_idempotent = Map.get(spec || %{}, :idempotent, true)

    # Probabilistic check from the explicit RNG
    {sample, rng} = :rand.uniform_s(rng)
    probability_check = sample < config.probability

    {command_allowed and command_idempotent and probability_check, rng}
  end

  @doc """
  Get the number of retry attempts for a stuttered command.

  Returns `{count, rng'}` where count is between 1 and max_repeats, drawn from
  the explicit `rng`.
  """
  @spec retry_count(Config.t(), rng()) :: {pos_integer(), rng()}
  def retry_count(%Config{max_repeats: max}, rng) do
    # At least 1 retry, up to max_repeats
    :rand.uniform_s(max, rng)
  end

  @doc """
  Get the delay in milliseconds before a retry attempt.

  Returns `{delay, rng'}`, drawn from the explicit `rng`.
  """
  @spec retry_delay_ms(Config.t(), rng()) :: {non_neg_integer(), rng()}
  def retry_delay_ms(%Config{delay_ms: {a, b}}, rng) do
    # Tolerate an inverted {max, min} tuple: :rand.uniform_s/2 raises on a
    # non-positive argument, so normalize the bounds before drawing.
    lo = min(a, b)
    hi = max(a, b)
    {sample, rng} = :rand.uniform_s(hi - lo + 1, rng)
    {lo + sample - 1, rng}
  end

  def retry_delay_ms(%Config{delay_ms: fixed}, rng) when is_integer(fixed) do
    {fixed, rng}
  end

  @doc """
  Get the idempotency key for a command if it provides one.
  """
  @spec get_idempotency_key(struct()) :: String.t() | nil
  def get_idempotency_key(command) do
    command_module = command.__struct__

    if function_exported?(command_module, :idempotency_key, 1) do
      command_module.idempotency_key(command)
    else
      nil
    end
  end

  @doc """
  Build the stutter context passed to adapters during execution.
  """
  @spec build_context(pos_integer(), boolean(), String.t() | nil) :: map()
  def build_context(attempt, is_retry, idempotency_key) do
    %{
      attempt: attempt,
      is_retry: is_retry,
      idempotency_key: idempotency_key
    }
  end

  @doc """
  Compare events from first execution with retry execution under the
  configuration's `using:` predicate.

  Returns `:match`, or `{:mismatch, exception}` (see
  `PropertyDamage.Equivalence.verdict/3`): a `false` answer is a
  `PropertyDamage.ComparisonMismatch` with the original events as `left` and
  the retry's as `right`.
  """
  @spec compare_events([struct()], [struct()], Config.t()) ::
          :match | {:mismatch, Exception.t()}
  def compare_events(original_events, retry_events, %Config{} = config) do
    PropertyDamage.Equivalence.verdict(config.using, original_events, retry_events)
  end
end
