defmodule PropertyDamage.FailureIntelligence.Fingerprint do
  @moduledoc """
  Extracts comparable features from failures for similarity analysis.

  A fingerprint captures the essential characteristics of a failure that can be
  used to compare it with other failures. This enables pattern detection and
  clustering of similar failures.
  """

  alias PropertyDamage.FailureReport

  @type t :: %__MODULE__{
          failure_type: atom(),
          check_name: atom() | nil,
          command_type: atom() | nil,
          command_shape: map(),
          event_types: [atom()],
          event_count: non_neg_integer(),
          sequence_length: non_neg_integer(),
          sequence_shape: [atom()],
          state_keys: [atom()],
          error_category: atom(),
          error_pattern: String.t() | nil
        }

  defstruct [
    :failure_type,
    :check_name,
    :command_type,
    :command_shape,
    :event_types,
    :event_count,
    :sequence_length,
    :sequence_shape,
    :state_keys,
    :error_category,
    :error_pattern
  ]

  @doc """
  Extracts a fingerprint from a FailureReport.

  The fingerprint captures structural and semantic features that can be
  compared across different failures.
  """
  @spec from_failure_report(FailureReport.t()) :: t()
  def from_failure_report(%FailureReport{} = report) do
    %__MODULE__{
      failure_type: report.failure_type,
      check_name: report.check_name,
      command_type: extract_command_type(report.command_at_failure),
      command_shape: extract_command_shape(report.command_at_failure),
      event_types: extract_event_types(report.events_at_failure),
      event_count: length(report.events_at_failure || []),
      sequence_length: extract_sequence_length(report.shrunk_sequence),
      sequence_shape: extract_sequence_shape(report.shrunk_sequence),
      state_keys: extract_state_keys(report.state_at_failure),
      error_category: categorize_error(report),
      error_pattern: extract_error_pattern(report.failure_message)
    }
  end

  @doc """
  Extracts a fingerprint from a raw failure result (not yet a FailureReport).
  """
  @spec from_raw_failure(map()) :: t()
  def from_raw_failure(failure) when is_map(failure) do
    %__MODULE__{
      failure_type: Map.get(failure, :failure_type, :unknown),
      check_name: Map.get(failure, :check_name),
      command_type: extract_command_type(Map.get(failure, :command)),
      command_shape: extract_command_shape(Map.get(failure, :command)),
      event_types: extract_event_types(Map.get(failure, :events, [])),
      event_count: length(Map.get(failure, :events, [])),
      sequence_length: extract_sequence_length(Map.get(failure, :sequence)),
      sequence_shape: extract_sequence_shape(Map.get(failure, :sequence)),
      state_keys: extract_state_keys(Map.get(failure, :state)),
      error_category: categorize_raw_error(failure),
      error_pattern: extract_error_pattern(Map.get(failure, :message))
    }
  end

  @doc """
  Returns a hash of the fingerprint for quick comparison.

  Two fingerprints with the same hash are likely (but not guaranteed) to be similar.
  """
  @spec hash(t()) :: binary()
  def hash(%__MODULE__{} = fp) do
    # Create a deterministic representation for hashing
    data =
      [
        fp.failure_type,
        fp.check_name,
        fp.command_type,
        fp.event_types,
        fp.sequence_shape,
        fp.error_category
      ]
      |> :erlang.term_to_binary()

    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Returns a short hash for display purposes.
  """
  @spec short_hash(t()) :: String.t()
  def short_hash(%__MODULE__{} = fp) do
    hash(fp) |> String.slice(0, 8)
  end

  # ============================================================================
  # Feature Extraction
  # ============================================================================

  defp extract_command_type(nil), do: nil

  defp extract_command_type(command) when is_struct(command) do
    command.__struct__
  end

  defp extract_command_type(%{__struct__: type}), do: type
  defp extract_command_type(_), do: :unknown

  defp extract_command_shape(nil), do: %{}

  defp extract_command_shape(command) when is_struct(command) do
    command
    |> Map.from_struct()
    |> extract_shape()
  end

  defp extract_command_shape(command) when is_map(command) do
    extract_shape(command)
  end

  defp extract_command_shape(_), do: %{}

  defp extract_shape(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _} -> k == :__struct__ end)
    |> Enum.map(fn {k, v} -> {k, type_of(v)} end)
    |> Map.new()
  end

  defp type_of(nil), do: nil
  defp type_of(v) when is_binary(v), do: :string
  defp type_of(v) when is_integer(v), do: :integer
  defp type_of(v) when is_float(v), do: :float
  defp type_of(v) when is_atom(v), do: :atom
  defp type_of(v) when is_list(v), do: :list
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_tuple(v), do: :tuple
  defp type_of(_), do: :other

  defp extract_event_types(nil), do: []

  defp extract_event_types(events) when is_list(events) do
    events
    |> Enum.map(&extract_command_type/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_sequence_length(nil), do: 0

  defp extract_sequence_length(%{commands: commands}) when is_list(commands) do
    length(commands)
  end

  defp extract_sequence_length(sequence) when is_list(sequence) do
    length(sequence)
  end

  defp extract_sequence_length(_), do: 0

  defp extract_sequence_shape(nil), do: []

  defp extract_sequence_shape(%{commands: commands}) when is_list(commands) do
    Enum.map(commands, &extract_command_type/1)
  end

  defp extract_sequence_shape(sequence) when is_list(sequence) do
    Enum.map(sequence, &extract_command_type/1)
  end

  defp extract_sequence_shape(_), do: []

  defp extract_state_keys(nil), do: []

  defp extract_state_keys(state) when is_map(state) do
    state
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
    |> Enum.sort()
  end

  defp extract_state_keys(_), do: []

  # ============================================================================
  # Error Categorization
  # ============================================================================

  defp categorize_error(%FailureReport{} = report) do
    cond do
      report.failure_type == :check_failed and report.check_name != nil ->
        :check_violation

      report.failure_type == :invariant_violated ->
        :invariant_violation

      report.failure_type == :precondition_failed ->
        :precondition_failure

      report.failure_type == :postcondition_failed ->
        :postcondition_failure

      report.failure_type == :exception ->
        categorize_exception(report.failure_message)

      report.failure_type == :adapter_error ->
        :adapter_error

      report.failure_type == :timeout ->
        :timeout

      true ->
        :unknown
    end
  end

  defp categorize_raw_error(failure) do
    failure_type = Map.get(failure, :failure_type, :unknown)
    message = Map.get(failure, :message, "")

    cond do
      failure_type == :check_failed -> :check_violation
      failure_type == :invariant_violated -> :invariant_violation
      failure_type == :precondition_failed -> :precondition_failure
      failure_type == :postcondition_failed -> :postcondition_failure
      failure_type == :exception -> categorize_exception(message)
      failure_type == :adapter_error -> :adapter_error
      failure_type == :timeout -> :timeout
      true -> :unknown
    end
  end

  defp categorize_exception(nil), do: :unknown_exception

  defp categorize_exception(message) when is_binary(message) do
    cond do
      message =~ ~r/ArgumentError|argument error/i -> :argument_error
      message =~ ~r/FunctionClauseError|no function clause/i -> :function_clause_error
      message =~ ~r/MatchError|no match/i -> :match_error
      message =~ ~r/KeyError|key.*not found/i -> :key_error
      message =~ ~r/ArithmeticError|arithmetic/i -> :arithmetic_error
      message =~ ~r/RuntimeError/i -> :runtime_error
      message =~ ~r/BadMapError/i -> :bad_map_error
      message =~ ~r/UndefinedFunctionError/i -> :undefined_function_error
      true -> :other_exception
    end
  end

  defp categorize_exception(_), do: :unknown_exception

  # ============================================================================
  # Error Pattern Extraction
  # ============================================================================

  defp extract_error_pattern(nil), do: nil

  defp extract_error_pattern(message) when is_binary(message) do
    # Extract a normalized pattern from the error message
    # Remove specific values but keep the structure
    message
    |> normalize_numbers()
    |> normalize_refs()
    |> normalize_whitespace()
    |> String.slice(0, 200)
  end

  defp extract_error_pattern(_), do: nil

  defp normalize_numbers(str) do
    # Replace specific numbers with placeholders
    str
    |> String.replace(~r/\b\d+\.\d+\b/, "<FLOAT>")
    |> String.replace(~r/\b\d+\b/, "<NUM>")
  end

  defp normalize_refs(str) do
    # Replace references/IDs with placeholders
    str
    |> String.replace(~r/\b[a-f0-9]{8,}\b/i, "<HEX>")
    |> String.replace(~r/\b(acc|ref|id)_[a-zA-Z0-9]+\b/, "<REF>")
  end

  defp normalize_whitespace(str) do
    str
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
