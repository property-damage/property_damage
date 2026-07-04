defmodule PropertyDamage.Error do
  @moduledoc """
  User-friendly error formatting and common error types.

  This module provides helpful error messages that guide users toward
  fixing problems rather than just reporting them.
  """

  @type error_context :: %{
          optional(:command) => struct(),
          optional(:command_index) => non_neg_integer(),
          optional(:check_name) => atom(),
          optional(:projection) => module(),
          optional(:adapter) => module(),
          optional(:model) => module(),
          optional(:seed) => integer()
        }

  # ============================================================================
  # Error Formatting
  # ============================================================================

  @doc """
  Formats an error reason into a user-friendly message.

  Takes the raw error reason from execution and returns a formatted string
  with context and suggestions for fixing the issue.
  """
  @spec format(term(), error_context()) :: String.t()
  def format(reason, context \\ %{})

  def format(%PropertyDamage.Failure{} = failure, context) do
    format_failure(PropertyDamage.Failure.kind(failure), failure, context)
  end

  def format({:precondition_failed, command_module}, context) do
    cmd_info = format_command_info(context)

    """
    Precondition Failed: #{inspect(command_module)}
    #{cmd_info}
    The command's precondition/1 returned false.

    This is usually not an error - PropertyDamage will try other commands.
    However, if you see this repeatedly for the same command, the precondition
    may be too restrictive or the model state never satisfies it.

    Suggestions:
      - Check #{inspect(command_module)}.precondition/1
      - Verify that earlier commands create the required state
      - Consider if the precondition is overly restrictive
    """
    |> String.trim()
  end

  def format(reason, context) do
    cmd_info = format_command_info(context)

    """
    Error
    #{cmd_info}
    Reason: #{format_message(reason)}

    An unexpected error occurred during test execution.
    """
    |> String.trim()
  end

  # ============================================================================
  # %Failure{} Formatting (keyed by kind)
  # ============================================================================

  defp format_failure(kind, failure, context)
       when kind in [:assertion_failed, :projection_violation] do
    check_name = PropertyDamage.Failure.name(failure)
    cmd_info = format_command_info(context)

    """
    Check Failed: #{inspect(check_name)}
    #{cmd_info}
    Reason: #{format_message(PropertyDamage.Failure.detail(failure))}

    The check returned an error after the command was executed.
    This usually indicates the system under test violated an expected invariant.

    Suggestions:
      - Review the check's logic in #{inspect(check_name)}
      - Examine the command that triggered the failure
      - Check if the system state is as expected
    """
    |> String.trim()
  end

  defp format_failure(:adapter_error, failure, context) do
    adapter = Map.get(context, :adapter, "adapter")
    cmd_info = format_command_info(context)

    """
    Adapter Error
    #{cmd_info}
    Adapter: #{inspect(adapter)}
    Error: #{format_message(PropertyDamage.Failure.detail(failure))}

    The adapter's execute/3 function returned an error or raised an exception.
    This usually indicates a problem communicating with the system under test.

    Suggestions:
      - Check that the SUT is running and accessible
      - Verify adapter configuration (URLs, credentials, etc.)
      - Look for network issues or timeouts
      - Check the adapter's execute/3 implementation
    """
    |> String.trim()
  end

  defp format_failure(:settle_timeout, failure, context) do
    cmd_info = format_command_info(context)

    """
    Settle Timeout
    #{cmd_info}
    Last error: #{format_message(PropertyDamage.Failure.detail(failure))}

    A probe or bridge command timed out waiting for eventual consistency.
    The system did not reach the expected state within the timeout period.

    Suggestions:
      - Increase the settle timeout in the command's command_spec :settle config
      - Check if the async operation is completing at all
      - Verify the expected condition will eventually be met
      - Look for deadlocks or stuck operations
    """
    |> String.trim()
  end

  defp format_failure(:idempotency_violation, failure, context) do
    cmd_info = format_command_info(context)
    violation = PropertyDamage.Failure.detail(failure)

    original = Map.get(violation, :original_events, [])
    retry = Map.get(violation, :retry_events, [])

    """
    Idempotency Violation
    #{cmd_info}
    Original events: #{inspect(original, pretty: true, limit: 5)}
    Retry events: #{inspect(retry, pretty: true, limit: 5)}

    Retrying the same command produced different events.
    This indicates the command is not idempotent.

    Suggestions:
      - Implement idempotency keys in the SUT
      - Use request deduplication
      - Ensure the command uses deterministic IDs
      - Consider if retry safety is required for this command
    """
    |> String.trim()
  end

  defp format_failure(:stutter_execution_failed, failure, context) do
    cmd_info = format_command_info(context)
    details = PropertyDamage.Failure.detail(failure)
    retry_number = Map.get(details, :retry_number, "?")
    error = Map.get(details, :error, "unknown")

    """
    Stutter Execution Failed
    #{cmd_info}
    Retry ##{retry_number} failed with: #{format_message(error)}

    A retry attempt during idempotency testing failed with an error.
    This may indicate timing issues or non-deterministic behavior.

    Suggestions:
      - Check if the SUT handles concurrent requests correctly
      - Verify there are no race conditions
      - Consider adding delays between retries
    """
    |> String.trim()
  end

  defp format_failure(:linearization, failure, context) do
    cmd_info = format_command_info(context)

    """
    Linearization Failed
    #{cmd_info}
    Details: #{format_message(PropertyDamage.Failure.detail(failure))}

    The parallel execution results cannot be explained by any sequential ordering.
    This indicates a race condition or concurrency bug in the SUT.

    Suggestions:
      - Look for missing locks or synchronization
      - Check for read-modify-write races
      - Verify transaction isolation levels
      - Consider if operations should be serialized
    """
    |> String.trim()
  end

  defp format_failure(:nemesis_error, failure, context) do
    cmd_info = format_command_info(context)

    """
    Nemesis Error
    #{cmd_info}
    Error: #{format_message(PropertyDamage.Failure.detail(failure))}

    A fault injection (nemesis) command failed to inject or restore.
    This is usually an infrastructure issue, not a SUT bug.

    Suggestions:
      - Verify fault injection infrastructure (toxiproxy, etc.)
      - Check nemesis command implementation
      - Ensure restore can run even if inject partially failed
    """
    |> String.trim()
  end

  defp format_failure(_kind, failure, context) do
    cmd_info = format_command_info(context)

    """
    Error
    #{cmd_info}
    Reason: #{format_message(PropertyDamage.Failure.detail(failure))}

    An unexpected error occurred during test execution.
    """
    |> String.trim()
  end

  # ============================================================================
  # Configuration Errors
  # ============================================================================

  @doc """
  Formats a configuration error with suggestions.
  """
  @spec format_config_error(atom(), term()) :: String.t()
  def format_config_error(:missing_model, _) do
    """
    Configuration Error: Missing Model

    The :model option is required but was not provided.

    Example:
      PropertyDamage.run(
        model: MyApp.TestModel,
        adapter: MyApp.TestAdapter
      )
    """
    |> String.trim()
  end

  def format_config_error(:missing_adapter, _) do
    """
    Configuration Error: Missing Adapter

    The :adapter option is required but was not provided.

    Example:
      PropertyDamage.run(
        model: MyApp.TestModel,
        adapter: MyApp.TestAdapter
      )
    """
    |> String.trim()
  end

  def format_config_error(:invalid_max_commands, value) do
    """
    Configuration Error: Invalid max_commands

    max_commands must be a positive integer, got: #{inspect(value)}

    Example:
      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        max_commands: 50
      )
    """
    |> String.trim()
  end

  def format_config_error(:invalid_max_runs, value) do
    """
    Configuration Error: Invalid max_runs

    max_runs must be a positive integer, got: #{inspect(value)}

    Example:
      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        max_runs: 100
      )
    """
    |> String.trim()
  end

  def format_config_error(:invalid_seed, value) do
    """
    Configuration Error: Invalid seed

    seed must be a positive integer, got: #{inspect(value)}

    Example:
      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        seed: 12345
      )
    """
    |> String.trim()
  end

  def format_config_error(:empty_commands, model) do
    """
    Configuration Error: No Commands

    Model #{inspect(model)} returned an empty command list.
    At least one command is required for testing.

    Check that #{inspect(model)}.commands/0 returns a non-empty list:

      def commands do
        [
          {MyApp.Commands.CreateUser, weight: 10},
          {MyApp.Commands.UpdateUser, weight: 5}
        ]
      end
    """
    |> String.trim()
  end

  def format_config_error(:invalid_command_weight, {weight, command}) do
    """
    Configuration Error: Invalid Command Weight

    Command #{inspect(command)} has invalid weight: #{inspect(weight)}
    Weights must be positive integers.

    Example:
      def commands do
        [
          {MyApp.Commands.CreateUser, weight: 10},  # weight 10
          {MyApp.Commands.UpdateUser, weight: 5}    # weight 5
        ]
      end
    """
    |> String.trim()
  end

  def format_config_error(:command_missing_callback, {command, callback, arity}) do
    """
    Configuration Error: Missing Command Callback

    Command #{inspect(command)} is missing required callback: #{callback}/#{arity}

    Commands must implement the PropertyDamage.Command behaviour:

      defmodule #{inspect(command)} do
        @behaviour PropertyDamage.Command

        defstruct [:field1, :field2]

        @impl true
        def new(state, _generators) do
          %__MODULE__{field1: "value"}
        end

        @impl true
        def precondition(_state), do: true

        @impl true
        def events(_command, response) do
          [%SomeEvent{data: response}]
        end
      end
    """
    |> String.trim()
  end

  def format_config_error(type, details) do
    """
    Configuration Error: #{inspect(type)}

    Details: #{inspect(details)}
    """
    |> String.trim()
  end

  # ============================================================================
  # Warnings
  # ============================================================================

  @doc """
  Formats a warning with context.
  """
  @spec format_warning(atom(), term()) :: String.t()
  def format_warning(:precondition_never_true, command) do
    "Command #{inspect(command)} precondition was never satisfied in any run. " <>
      "Consider if the precondition is too restrictive."
  end

  def format_warning(:check_never_failed, check) do
    "Check #{inspect(check)} never failed across all runs. " <>
      "This might indicate the check is too permissive or never triggered."
  end

  def format_warning(:low_command_coverage, {coverage, threshold}) do
    "Command coverage is #{Float.round(coverage, 1)}%, below threshold of #{threshold}%. " <>
      "Some commands may not be reachable."
  end

  def format_warning(:command_always_fails, command) do
    "Command #{inspect(command)} always failed when executed. " <>
      "Check the adapter implementation or SUT configuration."
  end

  def format_warning(type, details) do
    "Warning: #{inspect(type)} - #{inspect(details)}"
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_command_info(context) do
    parts = []

    parts =
      if Map.has_key?(context, :command) do
        cmd = context.command
        ["Command: #{inspect(cmd.__struct__)}" | parts]
      else
        parts
      end

    parts =
      if Map.has_key?(context, :command_index) do
        ["At index: #{context.command_index}" | parts]
      else
        parts
      end

    parts =
      if Map.has_key?(context, :seed) do
        ["Seed: #{context.seed}" | parts]
      else
        parts
      end

    case parts do
      [] -> ""
      _ -> Enum.reverse(parts) |> Enum.join("\n")
    end
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message) when is_atom(message), do: Atom.to_string(message)
  defp format_message(message), do: inspect(message, pretty: true, limit: 10)
end
