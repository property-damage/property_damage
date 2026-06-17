defmodule PropertyDamage.Stutter.Config do
  @moduledoc """
  Configuration for stutter testing.
  """

  @type t :: %__MODULE__{
          probability: float(),
          max_repeats: pos_integer(),
          delay_ms: {non_neg_integer(), non_neg_integer()} | non_neg_integer(),
          commands: :all | [module()],
          comparison: :strict | {:structural, [atom()]} | {:custom, function()},
          enabled: boolean()
        }

  defstruct [
    :probability,
    :max_repeats,
    :delay_ms,
    :commands,
    :comparison,
    :enabled
  ]
end

defmodule PropertyDamage.Stutter.Violation do
  @moduledoc """
  Represents an idempotency violation detected during stutter testing.
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
          comparison_result: term()
        }

  defstruct [
    :command,
    :command_index,
    :attempts,
    :comparison_result
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
        adapter: MyAdapter,
        stutter: %{
          probability: 0.1,      # 10% of commands stuttered
          max_repeats: 2,        # Up to 2 retries (3 total executions)
          delay_ms: {0, 100},    # Random delay between retries
          commands: :all,        # Or list of specific command modules
          comparison: :strict    # :strict, {:structural, fields}, {:custom, fn}
        }
      )

  ## Command Callbacks

  Commands can opt into idempotency testing by implementing:

  - `idempotent?/0` - Return true if command should be stuttered (default: true)
  - `idempotency_key/1` - Return the idempotency key for requests
  - `acceptable_retry_events/0` - Event modules acceptable as retry responses

  ## Comparison Modes

  - `:strict` - Events must be exactly equal
  - `{:structural, ignore_fields}` - Ignore specified fields when comparing
  - `{:custom, fun}` - Custom comparison function
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
      comparison: :strict,
      enabled: true
    }
  end

  @doc """
  Parse stutter configuration from options.

  Accepts either a map of options or `false` to disable.
  """
  @spec parse_config(map() | false | nil) :: Config.t() | nil
  def parse_config(nil), do: nil
  def parse_config(false), do: nil

  def parse_config(opts) when is_map(opts) do
    %Config{
      probability: Map.get(opts, :probability, 0.1),
      max_repeats: Map.get(opts, :max_repeats, 2),
      delay_ms: Map.get(opts, :delay_ms, {0, 100}),
      commands: Map.get(opts, :commands, :all),
      comparison: Map.get(opts, :comparison, :strict),
      enabled: true
    }
  end

  @doc """
  Determine if a command should be stuttered based on configuration.

  The probabilistic check reads the process RNG (`:rand`). Determinism comes
  from the executor seeding that RNG once per run (`:rand.seed(:exsss, seed)`
  before the run loop), not from any per-call seeding here: re-running with the
  same seed reproduces the same stutter decisions. The same applies to
  `retry_count/1` and `retry_delay_ms/1`.
  """
  @spec should_stutter?(struct(), Config.t()) :: boolean()
  def should_stutter?(_command, nil), do: false
  def should_stutter?(_command, %Config{enabled: false}), do: false

  def should_stutter?(command, %Config{} = config) do
    command_module = command.__struct__

    # Check if command is in the allowed list
    command_allowed =
      case config.commands do
        :all -> true
        modules when is_list(modules) -> command_module in modules
      end

    # Check if command declares itself as idempotent
    command_idempotent =
      if function_exported?(command_module, :idempotent?, 0) do
        command_module.idempotent?()
      else
        true
      end

    # Probabilistic check using seeded RNG
    probability_check = :rand.uniform() < config.probability

    command_allowed and command_idempotent and probability_check
  end

  @doc """
  Get the number of retry attempts for a stuttered command.

  Returns a random number between 1 and max_repeats.
  """
  @spec retry_count(Config.t()) :: pos_integer()
  def retry_count(%Config{max_repeats: max}) do
    # At least 1 retry, up to max_repeats
    :rand.uniform(max)
  end

  @doc """
  Get the delay in milliseconds before a retry attempt.
  """
  @spec retry_delay_ms(Config.t()) :: non_neg_integer()
  def retry_delay_ms(%Config{delay_ms: {a, b}}) do
    # Tolerate an inverted {max, min} tuple: :rand.uniform/1 raises on a
    # non-positive argument, so normalize the bounds before drawing.
    lo = min(a, b)
    hi = max(a, b)
    lo + :rand.uniform(hi - lo + 1) - 1
  end

  def retry_delay_ms(%Config{delay_ms: fixed}) when is_integer(fixed) do
    fixed
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
  Compare events from first execution with retry execution.

  Returns `:match` if events are considered equivalent, or
  `{:mismatch, details}` if they differ.
  """
  @spec compare_events([struct()], [struct()], Config.t(), struct()) ::
          :match | {:mismatch, map()}
  def compare_events(original_events, retry_events, config, command) do
    case config.comparison do
      :strict ->
        compare_strict(original_events, retry_events)

      {:structural, ignore_fields} ->
        compare_structural(original_events, retry_events, ignore_fields)

      {:custom, fun} when is_function(fun, 2) ->
        fun.(original_events, retry_events)

      _ ->
        compare_with_acceptable(original_events, retry_events, command)
    end
  end

  defp compare_strict(original, retry) do
    if original == retry do
      :match
    else
      {:mismatch, %{expected: original, actual: retry, mode: :strict}}
    end
  end

  defp compare_structural(original, retry, ignore_fields) do
    normalized_original = Enum.map(original, &drop_fields(&1, ignore_fields))
    normalized_retry = Enum.map(retry, &drop_fields(&1, ignore_fields))

    if normalized_original == normalized_retry do
      :match
    else
      {:mismatch,
       %{
         expected: normalized_original,
         actual: normalized_retry,
         mode: :structural,
         ignored_fields: ignore_fields
       }}
    end
  end

  defp drop_fields(event, fields) when is_struct(event) do
    event
    |> Map.from_struct()
    |> Map.drop(fields)
    |> then(&struct(event.__struct__, &1))
  end

  defp drop_fields(event, _fields), do: event

  defp compare_with_acceptable(original_events, retry_events, command) do
    command_module = command.__struct__

    acceptable_modules =
      if function_exported?(command_module, :acceptable_retry_events, 0) do
        command_module.acceptable_retry_events()
      else
        []
      end

    # If retry events are from acceptable modules, it's a match
    retry_modules = Enum.map(retry_events, & &1.__struct__)

    all_acceptable =
      Enum.all?(retry_modules, fn mod ->
        mod in acceptable_modules or mod in Enum.map(original_events, & &1.__struct__)
      end)

    if original_events == retry_events do
      :match
    else
      if all_acceptable and length(retry_events) == length(original_events) do
        :match
      else
        {:mismatch, %{expected: original_events, actual: retry_events, mode: :acceptable_check}}
      end
    end
  end
end
