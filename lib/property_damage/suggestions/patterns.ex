defmodule PropertyDamage.Suggestions.Patterns do
  @moduledoc """
  Pattern detection for property and invariant suggestions.

  Identifies common patterns in events and commands that typically require
  specific invariant checks.
  """

  @type pattern :: %{
          type: atom(),
          field: atom(),
          event: module() | nil,
          command: module() | nil,
          value_type: atom(),
          confidence: float()
        }

  # Field name patterns that suggest specific check types
  @numeric_patterns ~w(
    balance amount total count quantity price cost value
    available_balance pending_amount captured_amount
    credit debit deposit withdrawal fee tax discount
    min max limit threshold score rating
  )a

  @currency_patterns ~w(currency currency_code iso_currency)a

  @reference_patterns ~w(
    _ref _id account_ref user_ref order_ref transaction_ref
    authorization_ref capture_ref parent_ref source_ref target_ref
    owner_id user_id account_id customer_id
  )

  @status_patterns ~w(status state phase stage)a

  @timestamp_patterns ~w(
    _at created_at updated_at inserted_at deleted_at
    started_at completed_at expired_at expires_at
    timestamp time date
  )

  @doc """
  Detects patterns in event struct fields.

  Returns a list of detected patterns with their types and confidence levels.
  """
  @spec detect_patterns(module()) :: [pattern()]
  def detect_patterns(event_module) when is_atom(event_module) do
    if struct_module?(event_module) do
      fields = get_struct_fields(event_module)

      fields
      |> Enum.flat_map(fn field ->
        detect_field_patterns(field, event_module)
      end)
    else
      []
    end
  end

  @doc """
  Detects patterns across multiple event modules.
  """
  @spec detect_patterns_multi([module()]) :: [pattern()]
  def detect_patterns_multi(event_modules) do
    event_modules
    |> Enum.flat_map(&detect_patterns/1)
    |> group_related_patterns()
  end

  @doc """
  Identifies fields that appear across multiple events (cross-event fields).

  These are prime candidates for consistency checks.
  """
  @spec find_cross_event_fields([module()]) :: [{atom(), [module()]}]
  def find_cross_event_fields(event_modules) do
    event_modules
    |> Enum.flat_map(fn mod ->
      if struct_module?(mod) do
        get_struct_fields(mod)
        |> Enum.map(fn field -> {field, mod} end)
      else
        []
      end
    end)
    |> Enum.group_by(fn {field, _mod} -> field end, fn {_field, mod} -> mod end)
    |> Enum.filter(fn {_field, mods} -> length(mods) > 1 end)
    |> Enum.sort_by(fn {_field, mods} -> -length(mods) end)
  end

  @doc """
  Analyzes a field and returns suggested check types.
  """
  @spec suggest_checks_for_field(atom(), keyword()) :: [atom()]
  def suggest_checks_for_field(field, opts \\ []) do
    field_str = Atom.to_string(field)

    checks = []

    # Numeric field checks
    checks =
      if numeric_field?(field) do
        checks ++ [:non_negative, :reasonable_bounds]
      else
        checks
      end

    # Currency field checks
    checks =
      if currency_field?(field) do
        checks ++ [:currency_consistency, :valid_currency_code]
      else
        checks
      end

    # Reference field checks
    checks =
      if reference_field?(field) do
        checks ++ [:reference_exists, :reference_valid]
      else
        checks
      end

    # Status field checks
    checks =
      if status_field?(field) do
        checks ++ [:valid_status, :valid_transition]
      else
        checks
      end

    # Timestamp field checks
    checks =
      if timestamp_field?(field_str) do
        checks ++ [:timestamp_ordering, :not_future]
      else
        checks
      end

    # Filter by focus if specified
    case Keyword.get(opts, :focus) do
      nil -> checks
      :numeric -> Enum.filter(checks, &(&1 in [:non_negative, :reasonable_bounds]))
      :references -> Enum.filter(checks, &(&1 in [:reference_exists, :reference_valid]))
      :consistency -> Enum.filter(checks, &(&1 in [:currency_consistency, :valid_status]))
      _ -> checks
    end
  end

  @doc """
  Returns the pattern type for a field.
  """
  @spec field_pattern_type(atom()) :: atom() | nil
  def field_pattern_type(field) do
    field_str = Atom.to_string(field)

    # Check reference first since it's more specific
    cond do
      reference_field?(field) -> :reference
      currency_field?(field) -> :currency
      status_field?(field) -> :status
      timestamp_field?(field_str) -> :timestamp
      numeric_field?(field) -> :numeric
      true -> nil
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp detect_field_patterns(field, event_module) do
    field_str = Atom.to_string(field)
    patterns = []

    # Numeric patterns
    patterns =
      if numeric_field?(field) do
        patterns ++
          [
            %{
              type: :numeric,
              field: field,
              event: event_module,
              command: nil,
              value_type: :number,
              confidence: calculate_confidence(field, :numeric)
            }
          ]
      else
        patterns
      end

    # Currency patterns
    patterns =
      if currency_field?(field) do
        patterns ++
          [
            %{
              type: :currency,
              field: field,
              event: event_module,
              command: nil,
              value_type: :string,
              confidence: 0.95
            }
          ]
      else
        patterns
      end

    # Reference patterns
    patterns =
      if reference_field?(field) do
        patterns ++
          [
            %{
              type: :reference,
              field: field,
              event: event_module,
              command: nil,
              value_type: :ref,
              confidence: calculate_confidence(field, :reference)
            }
          ]
      else
        patterns
      end

    # Status patterns
    patterns =
      if status_field?(field) do
        patterns ++
          [
            %{
              type: :status,
              field: field,
              event: event_module,
              command: nil,
              value_type: :atom_or_string,
              confidence: 0.9
            }
          ]
      else
        patterns
      end

    # Timestamp patterns
    patterns =
      if timestamp_field?(field_str) do
        patterns ++
          [
            %{
              type: :timestamp,
              field: field,
              event: event_module,
              command: nil,
              value_type: :datetime,
              confidence: 0.85
            }
          ]
      else
        patterns
      end

    patterns
  end

  defp numeric_field?(field) do
    field_str = Atom.to_string(field)

    # Don't match if it's a reference field
    if reference_field?(field) do
      false
    else
      # Only match "count" if it's a standalone word or at the end.
      # Enum.member? instead of `in`: the `in` expansion inside `or` chains
      # trips an "unsafe variable" error in Erlang's cover compiler.
      Enum.member?(@numeric_patterns, field) or
        (String.contains?(field_str, ["amount", "balance", "total", "price"]) or
           String.ends_with?(field_str, "count") or
           String.ends_with?(field_str, "_count"))
    end
  end

  defp currency_field?(field) do
    field in @currency_patterns
  end

  defp reference_field?(field) do
    field_str = Atom.to_string(field)

    Enum.any?(@reference_patterns, fn pattern ->
      String.ends_with?(field_str, pattern) or String.contains?(field_str, "_ref")
    end)
  end

  defp status_field?(field) do
    field in @status_patterns
  end

  defp timestamp_field?(field_str) do
    Enum.any?(@timestamp_patterns, fn pattern ->
      String.ends_with?(field_str, pattern) or String.contains?(field_str, "time")
    end)
  end

  defp calculate_confidence(field, :numeric) do
    field_str = Atom.to_string(field)

    cond do
      Enum.member?([:balance, :amount, :total], field) -> 0.95
      String.contains?(field_str, "balance") -> 0.95
      String.contains?(field_str, "amount") -> 0.90
      String.contains?(field_str, "count") -> 0.85
      true -> 0.75
    end
  end

  defp calculate_confidence(field, :reference) do
    field_str = Atom.to_string(field)

    cond do
      String.ends_with?(field_str, "_ref") -> 0.95
      String.ends_with?(field_str, "_id") -> 0.90
      true -> 0.80
    end
  end

  defp group_related_patterns(patterns) do
    # Group by field to avoid duplicates and increase confidence
    patterns
    |> Enum.group_by(fn p -> {p.type, p.field} end)
    |> Enum.map(fn {{type, field}, group} ->
      # Merge patterns for the same field/type across events
      events = Enum.map(group, & &1.event) |> Enum.uniq()
      max_confidence = Enum.map(group, & &1.confidence) |> Enum.max()

      %{
        type: type,
        field: field,
        events: events,
        event: hd(events),
        command: nil,
        value_type: hd(group).value_type,
        confidence: min(max_confidence + 0.05 * (length(events) - 1), 1.0)
      }
    end)
    |> Enum.sort_by(& &1.confidence, :desc)
  end

  defp struct_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0)
  end

  defp get_struct_fields(module) do
    module.__struct__()
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
  end
end
