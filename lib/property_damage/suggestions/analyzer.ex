defmodule PropertyDamage.Suggestions.Analyzer do
  @moduledoc """
  Core analyzer for property and invariant suggestions.

  Examines a model's structure and generates suggestions for missing checks.
  """

  alias PropertyDamage.Model
  alias PropertyDamage.Suggestions.Patterns

  @doc """
  Analyzes a model and returns a comprehensive analysis with suggestions.
  """
  @spec analyze(module(), keyword()) :: map()
  def analyze(model, opts \\ []) do
    # Get model components
    commands = get_commands(model)
    assertion_projections = get_assertion_projections(model)

    # Extract events from commands
    events = extract_events_from_commands(commands)

    # Detect patterns in events
    patterns = Patterns.detect_patterns_multi(events)

    # Get existing checks
    existing_checks = extract_existing_checks(assertion_projections)

    # Find cross-event fields (consistency check candidates)
    cross_event_fields = Patterns.find_cross_event_fields(events)

    # Generate suggestions
    suggestions =
      generate_suggestions(patterns, existing_checks, cross_event_fields, events, opts)

    # Calculate field coverage
    field_coverage = calculate_field_coverage(patterns, existing_checks)

    # Build analysis result
    %{
      model: model,
      suggestions: maybe_limit_suggestions(suggestions, opts),
      detected_patterns: patterns,
      existing_checks: existing_checks,
      field_coverage: field_coverage,
      cross_event_fields: cross_event_fields,
      events_analyzed: length(events),
      summary: generate_summary(suggestions, patterns, existing_checks)
    }
  end

  # ============================================================================
  # Model Extraction
  # ============================================================================

  defp get_commands(model) do
    if function_exported?(model, :commands, 0) do
      model.commands()
      |> Model.normalize_commands()
      |> Enum.map(fn {_weight, cmd} -> cmd end)
    else
      []
    end
  end

  defp get_assertion_projections(model) do
    if function_exported?(model, :assertion_projections, 0) do
      model.assertion_projections()
    else
      []
    end
  end

  defp extract_events_from_commands(commands) do
    commands
    |> Enum.flat_map(fn cmd_module ->
      # Try to get events from module attributes or function
      get_emitted_events(cmd_module)
    end)
    |> Enum.uniq()
  end

  defp get_emitted_events(cmd_module) do
    if function_exported?(cmd_module, :__info__, 1) do
      # Check for @emits module attribute
      attrs = cmd_module.__info__(:attributes)

      case Keyword.get(attrs, :emits) do
        nil -> infer_events_from_module_name(cmd_module)
        events -> List.flatten(events)
      end
    else
      infer_events_from_module_name(cmd_module)
    end
  end

  defp infer_events_from_module_name(cmd_module) do
    # Try to infer event modules from command module naming conventions
    # e.g., MyApp.Commands.CreateAccount -> MyApp.Events.AccountCreated
    cmd_parts = Module.split(cmd_module)
    cmd_name = List.last(cmd_parts)
    base_parts = Enum.drop(cmd_parts, -2)

    # Common event name transformations
    event_names =
      case cmd_name do
        "Create" <> entity ->
          ["#{entity}Created", "#{entity}Failed", "Create#{entity}Failed"]

        "Update" <> entity ->
          ["#{entity}Updated", "#{entity}Failed", "Update#{entity}Failed"]

        "Delete" <> entity ->
          ["#{entity}Deleted", "#{entity}Failed", "Delete#{entity}Failed"]

        "Get" <> entity ->
          ["#{entity}Viewed", "#{entity}Retrieved", "ViewFailed"]

        "Close" <> entity ->
          ["#{entity}Closed", "CloseFailed"]

        "Release" <> entity ->
          ["#{entity}Released", "ReleaseFailed"]

        "Adjust" <> entity ->
          ["#{entity}Adjusted", "AdjustmentFailed"]

        "Credit" <> entity ->
          ["#{entity}Credited", "CreditFailed"]

        "Debit" <> entity ->
          ["#{entity}Debited", "DebitFailed"]

        "Verify" <> entity ->
          ["#{entity}Verified", "VerificationFailed"]

        _ ->
          []
      end

    # Try to find matching event modules
    event_names
    |> Enum.flat_map(fn event_name ->
      # Try Events namespace
      events_module = Module.concat(base_parts ++ ["Events", event_name])

      if Code.ensure_loaded?(events_module) and function_exported?(events_module, :__struct__, 0) do
        [events_module]
      else
        []
      end
    end)
  end

  # ============================================================================
  # Check Extraction
  # ============================================================================

  defp extract_existing_checks(assertion_projections) do
    assertion_projections
    |> Enum.flat_map(fn projection ->
      # Check for __assertions__/0 (new) or __checks__/0 (legacy)
      cond do
        function_exported?(projection, :__assertions__, 0) ->
          projection.__assertions__()
          |> Enum.map(fn check ->
            Map.put(check, :projection, projection)
          end)

        function_exported?(projection, :__checks__, 0) ->
          projection.__checks__()
          |> Enum.map(fn check ->
            Map.put(check, :projection, projection)
          end)

        true ->
          []
      end
    end)
  end

  # ============================================================================
  # Suggestion Generation
  # ============================================================================

  defp generate_suggestions(patterns, existing_checks, cross_event_fields, events, opts) do
    focus = Keyword.get(opts, :focus, :all)
    include_low = Keyword.get(opts, :include_low_priority, true)

    suggestions = []

    # Numeric field suggestions
    suggestions =
      if Enum.member?([:all, :numeric], focus) do
        suggestions ++ generate_numeric_suggestions(patterns, existing_checks)
      else
        suggestions
      end

    # Currency consistency suggestions
    suggestions =
      if Enum.member?([:all, :consistency], focus) do
        suggestions ++
          generate_currency_suggestions(patterns, cross_event_fields, existing_checks)
      else
        suggestions
      end

    # Reference field suggestions
    suggestions =
      if Enum.member?([:all, :references], focus) do
        suggestions ++ generate_reference_suggestions(patterns, existing_checks)
      else
        suggestions
      end

    # Status/state transition suggestions
    suggestions =
      if Enum.member?([:all, :status], focus) do
        suggestions ++ generate_status_suggestions(patterns, existing_checks)
      else
        suggestions
      end

    # Cross-event consistency suggestions
    suggestions =
      if Enum.member?([:all, :consistency], focus) do
        suggestions ++ generate_cross_event_suggestions(cross_event_fields, existing_checks)
      else
        suggestions
      end

    # Event coverage suggestions
    suggestions = suggestions ++ generate_event_coverage_suggestions(events, existing_checks)

    # Filter and sort
    suggestions =
      suggestions
      |> Enum.uniq_by(fn s -> {s.type, s.field, s.event} end)
      |> Enum.sort_by(fn s -> {priority_order(s.priority), -confidence_score(s)} end)

    # Filter low priority if requested
    if include_low do
      suggestions
    else
      Enum.reject(suggestions, &(&1.priority == :low))
    end
  end

  defp generate_numeric_suggestions(patterns, existing_checks) do
    numeric_patterns = Enum.filter(patterns, &(&1.type == :numeric))

    # Check which numeric fields already have non-negative checks
    checked_fields = extract_checked_fields(existing_checks, :numeric)

    numeric_patterns
    |> Enum.reject(fn p -> p.field in checked_fields end)
    |> Enum.map(fn pattern ->
      %{
        type: :non_negative_check,
        priority: if(pattern.confidence > 0.9, do: :high, else: :medium),
        field: pattern.field,
        event: pattern.event,
        command: nil,
        description: "Add non-negative check for #{pattern.field}",
        rationale:
          "The field '#{pattern.field}' appears to be a numeric value (#{describe_events(pattern)}). " <>
            "Numeric fields like balances, amounts, and counts should typically never be negative.",
        example_code: generate_non_negative_check_code(pattern),
        confidence: pattern.confidence
      }
    end)
  end

  defp generate_currency_suggestions(patterns, cross_event_fields, existing_checks) do
    currency_patterns = Enum.filter(patterns, &(&1.type == :currency))
    checked_fields = extract_checked_fields(existing_checks, :currency)

    suggestions =
      currency_patterns
      |> Enum.reject(fn p -> p.field in checked_fields end)
      |> Enum.map(fn pattern ->
        %{
          type: :currency_consistency,
          priority: :high,
          field: pattern.field,
          event: pattern.event,
          command: nil,
          description: "Add currency consistency check",
          rationale:
            "Currency field '#{pattern.field}' appears in events. Operations should use " <>
              "consistent currencies - e.g., you can't credit USD to a EUR account.",
          example_code: generate_currency_check_code(pattern),
          confidence: pattern.confidence
        }
      end)

    # Also check for currency fields appearing in multiple events
    currency_cross =
      Enum.find(cross_event_fields, fn {field, _events} ->
        field in [:currency, :currency_code]
      end)

    if currency_cross && :currency not in checked_fields do
      {field, events} = currency_cross

      suggestions ++
        [
          %{
            type: :cross_event_currency,
            priority: :high,
            field: field,
            event: hd(events),
            command: nil,
            description: "Add cross-operation currency consistency check",
            rationale:
              "Currency field appears in #{length(events)} event types. " <>
                "Ensure all operations on the same entity use matching currencies.",
            example_code: generate_cross_currency_check_code(field, events),
            confidence: 0.95
          }
        ]
    else
      suggestions
    end
  end

  defp generate_reference_suggestions(patterns, existing_checks) do
    ref_patterns = Enum.filter(patterns, &(&1.type == :reference))
    checked_fields = extract_checked_fields(existing_checks, :reference)

    ref_patterns
    |> Enum.reject(fn p -> p.field in checked_fields end)
    |> Enum.map(fn pattern ->
      %{
        type: :reference_exists,
        priority: if(pattern.confidence > 0.9, do: :medium, else: :low),
        field: pattern.field,
        event: pattern.event,
        command: nil,
        description: "Add reference existence check for #{pattern.field}",
        rationale:
          "The field '#{pattern.field}' appears to be a reference to another entity. " <>
            "Consider validating that referenced entities exist in your model state.",
        example_code: generate_reference_check_code(pattern),
        confidence: pattern.confidence
      }
    end)
  end

  defp generate_status_suggestions(patterns, existing_checks) do
    status_patterns = Enum.filter(patterns, &(&1.type == :status))
    checked_fields = extract_checked_fields(existing_checks, :status)

    status_patterns
    |> Enum.reject(fn p -> p.field in checked_fields end)
    |> Enum.map(fn pattern ->
      %{
        type: :valid_status_transition,
        priority: :medium,
        field: pattern.field,
        event: pattern.event,
        command: nil,
        description: "Add status transition validation for #{pattern.field}",
        rationale:
          "The field '#{pattern.field}' appears to track entity state. " <>
            "Consider validating that status transitions follow allowed paths.",
        example_code: generate_status_check_code(pattern),
        confidence: pattern.confidence
      }
    end)
  end

  defp generate_cross_event_suggestions(cross_event_fields, existing_checks) do
    # Find fields that appear in multiple events but aren't checked
    checked_field_names =
      existing_checks
      |> Enum.flat_map(fn check ->
        extract_field_names_from_check(check)
      end)
      |> Enum.uniq()

    cross_event_fields
    |> Enum.reject(fn {field, _events} ->
      # Skip common fields that don't need consistency checks
      Enum.member?([:__struct__, :inserted_at, :updated_at, :id], field) or
        Enum.member?(checked_field_names, field)
    end)
    |> Enum.filter(fn {field, events} ->
      # Only suggest for fields with multiple appearances and meaningful names
      length(events) >= 2 and Patterns.field_pattern_type(field) != nil
    end)
    |> Enum.take(5)
    |> Enum.map(fn {field, events} ->
      pattern_type = Patterns.field_pattern_type(field)

      %{
        type: :cross_event_consistency,
        priority: if(pattern_type in [:numeric, :currency], do: :medium, else: :low),
        field: field,
        event: hd(events),
        command: nil,
        description: "Add consistency check for #{field} across operations",
        rationale:
          "Field '#{field}' appears in #{length(events)} event types. " <>
            "Consider checking that values remain consistent where expected.",
        example_code: nil,
        confidence: 0.7
      }
    end)
  end

  defp generate_event_coverage_suggestions(events, existing_checks) do
    # Find events that don't seem to be covered by any check
    check_triggers =
      existing_checks
      |> Enum.flat_map(fn check ->
        case check.trigger do
          :always -> []
          [{:after, modules}] -> modules
          _ -> []
        end
      end)
      |> Enum.uniq()

    uncovered_events =
      events
      |> Enum.reject(fn event ->
        event in check_triggers or
          String.contains?(inspect(event), "Failed") or
          String.contains?(inspect(event), "Viewed")
      end)

    uncovered_events
    |> Enum.take(3)
    |> Enum.map(fn event ->
      event_name = event |> Module.split() |> List.last()

      %{
        type: :event_coverage,
        priority: :low,
        field: nil,
        event: event,
        command: nil,
        description: "Consider adding a check triggered by #{event_name}",
        rationale:
          "The event #{event_name} doesn't appear to trigger any specific checks. " <>
            "Consider whether any invariants should be validated when this event occurs.",
        example_code: generate_event_trigger_check_code(event),
        confidence: 0.5
      }
    end)
  end

  # ============================================================================
  # Coverage Calculation
  # ============================================================================

  defp calculate_field_coverage(patterns, existing_checks) do
    all_fields =
      patterns
      |> Enum.map(& &1.field)
      |> Enum.uniq()

    checked_fields =
      existing_checks
      |> Enum.flat_map(&extract_field_names_from_check/1)
      |> Enum.uniq()

    covered = Enum.filter(all_fields, &(&1 in checked_fields))
    uncovered = Enum.reject(all_fields, &(&1 in checked_fields))

    coverage_pct =
      if all_fields != [] do
        Float.round(length(covered) / length(all_fields) * 100, 1)
      else
        100.0
      end

    %{
      total_fields: length(all_fields),
      covered_fields: length(covered),
      uncovered_fields: uncovered,
      coverage_percentage: coverage_pct
    }
  end

  defp extract_checked_fields(checks, pattern_type) do
    # This is a heuristic - we look at check names and triggers
    checks
    |> Enum.filter(fn check ->
      check_name = Atom.to_string(check.name)

      case pattern_type do
        :numeric ->
          String.contains?(check_name, ["balance", "amount", "negative", "positive", "non_neg"])

        :currency ->
          String.contains?(check_name, ["currency", "consistency"])

        :reference ->
          String.contains?(check_name, ["ref", "exists", "valid"])

        :status ->
          String.contains?(check_name, ["status", "state", "transition"])

        _ ->
          false
      end
    end)
    |> Enum.flat_map(&extract_field_names_from_check/1)
  end

  defp extract_field_names_from_check(check) do
    # Extract field names from check name
    name_parts =
      check.name
      |> Atom.to_string()
      |> String.split("_")
      |> Enum.map(&String.to_atom/1)

    # Also look at triggers for hints
    trigger_fields =
      case check.trigger do
        [{:after, modules}] ->
          modules
          |> Enum.flat_map(fn mod ->
            if Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0) do
              mod.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))
            else
              []
            end
          end)

        _ ->
          []
      end

    (name_parts ++ trigger_fields) |> Enum.uniq()
  end

  # ============================================================================
  # Code Generation
  # ============================================================================

  defp generate_non_negative_check_code(pattern) do
    field = pattern.field

    """
    check(:always)
    def check(:#{field}_non_negative, state, _ctx) do
      # Check that #{field} is never negative
      violations =
        state.entities
        |> Enum.filter(fn {_id, entity} ->
          Map.get(entity, :#{field}, 0) < 0
        end)

      if Enum.empty?(violations) do
        :ok
      else
        {:error, "Negative #{field} detected: \#{inspect(violations)}"}
      end
    end
    """
  end

  defp generate_currency_check_code(_pattern) do
    """
    check(:always)
    def check(:currency_consistency, state, _ctx) do
      # Check that operations use matching currencies
      violations =
        state.operations
        |> Enum.filter(fn op ->
          entity = Map.get(state.entities, op.entity_ref)
          entity && entity.currency != op.currency
        end)

      if Enum.empty?(violations) do
        :ok
      else
        {:error, "Currency mismatch: \#{inspect(violations)}"}
      end
    end
    """
  end

  defp generate_cross_currency_check_code(field, _events) do
    """
    check(:always)
    def check(:#{field}_consistency, state, _ctx) do
      # Verify currency remains consistent across all operations on an entity
      violations =
        state.entities
        |> Enum.filter(fn {_id, entity} ->
          operations = get_operations_for(state, entity.ref)
          currencies = Enum.map(operations, & &1.#{field}) |> Enum.uniq()
          length(currencies) > 1
        end)

      if Enum.empty?(violations) do
        :ok
      else
        {:error, "Inconsistent #{field} across operations: \#{inspect(violations)}"}
      end
    end
    """
  end

  defp generate_reference_check_code(pattern) do
    field = pattern.field

    entity_type =
      field |> Atom.to_string() |> String.replace("_ref", "") |> String.replace("_id", "")

    """
    check(:always)
    def check(:#{field}_exists, state, _ctx) do
      # Verify that referenced #{entity_type} exists
      refs_in_use =
        state.operations
        |> Enum.map(& &1.#{field})
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      known_refs = Map.keys(state.#{entity_type}s)

      missing = refs_in_use -- known_refs

      if Enum.empty?(missing) do
        :ok
      else
        {:error, "References to non-existent #{entity_type}: \#{inspect(missing)}"}
      end
    end
    """
  end

  defp generate_status_check_code(pattern) do
    field = pattern.field

    """
    check(:always)
    def check(:valid_#{field}_transition, state, ctx) do
      # Define valid status transitions
      valid_transitions = %{
        :pending => [:active, :cancelled],
        :active => [:completed, :cancelled],
        :completed => [],
        :cancelled => []
      }

      # Check that the transition is valid
      case ctx.events do
        [%{#{field}: new_status} | _] ->
          old_status = get_previous_status(state, ctx)
          allowed = Map.get(valid_transitions, old_status, [])

          if new_status in allowed do
            :ok
          else
            {:error, "Invalid transition from \#{old_status} to \#{new_status}"}
          end

        _ ->
          :ok
      end
    end
    """
  end

  defp generate_event_trigger_check_code(event) do
    event_name = event |> Module.split() |> List.last()
    check_name = event_name |> Macro.underscore()

    """
    check(after: #{inspect(event)})
    def check(:after_#{check_name}, state, ctx) do
      # Add validation logic for when #{event_name} occurs
      :ok
    end
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp describe_events(pattern) do
    case Map.get(pattern, :events) do
      nil ->
        event_name = pattern.event |> Module.split() |> List.last()
        "seen in #{event_name}"

      events when is_list(events) ->
        names = Enum.map(events, fn e -> e |> Module.split() |> List.last() end)
        "seen in #{Enum.join(names, ", ")}"
    end
  end

  defp priority_order(:high), do: 0
  defp priority_order(:medium), do: 1
  defp priority_order(:low), do: 2

  defp confidence_score(suggestion) do
    Map.get(suggestion, :confidence, 0.5)
  end

  defp maybe_limit_suggestions(suggestions, opts) do
    case Keyword.get(opts, :max_suggestions) do
      nil -> suggestions
      max -> Enum.take(suggestions, max)
    end
  end

  defp generate_summary(suggestions, patterns, existing_checks) do
    high = Enum.count(suggestions, &(&1.priority == :high))
    medium = Enum.count(suggestions, &(&1.priority == :medium))
    low = Enum.count(suggestions, &(&1.priority == :low))

    pattern_types =
      patterns
      |> Enum.map(& &1.type)
      |> Enum.frequencies()

    """
    Analyzed #{length(patterns)} field patterns and #{length(existing_checks)} existing checks.
    Found #{length(suggestions)} suggestions: #{high} high, #{medium} medium, #{low} low priority.
    Patterns detected: #{inspect(pattern_types)}
    """
    |> String.trim()
  end
end
