defmodule PropertyDamage.Mutation.Operators.Boundary do
  @moduledoc false

  @behaviour PropertyDamage.Mutation.Operator

  alias PropertyDamage.Mutation.Operator

  @max_int 9_999_999_999
  @min_int -9_999_999_999
  @long_string String.duplicate("x", 10_000)

  @impl true
  def name, do: :boundary

  @impl true
  def description, do: "Pushes values to boundary cases (0, -1, max, nil, etc.)"

  @impl true
  def generate_mutations(events, opts \\ []) do
    max_mutations = Keyword.get(opts, :max_mutations, 10)

    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, event_idx} ->
      generate_event_boundary_mutations(event, event_idx)
    end)
    |> Enum.take(max_mutations)
  end

  @impl true
  def apply_mutation(events, mutation) do
    %{event_index: event_idx, target: field, mutated: new_value} = mutation

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      if idx == event_idx and is_struct(event) and Map.has_key?(event, field) do
        Map.put(event, field, new_value)
      else
        event
      end
    end)
  end

  @impl true
  def describe_mutation(mutation) do
    %{type: type, target: target, original: original, mutated: mutated} = mutation

    case type do
      :zero -> "#{target}: #{original} → 0"
      :negative -> "#{target}: #{original} → -1"
      :max_int -> "#{target}: #{original} → MAX_INT"
      :min_int -> "#{target}: #{original} → MIN_INT"
      :empty_string -> "#{target}: \"#{truncate(original)}\" → \"\""
      :whitespace -> "#{target}: \"#{truncate(original)}\" → \"   \""
      :very_long -> "#{target}: \"#{truncate(original)}\" → (10000 chars)"
      :null -> "#{target}: #{inspect(original)} → nil"
      _ -> "#{target}: #{inspect(original)} → #{inspect(mutated)}"
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_event_boundary_mutations(event, event_idx) when is_struct(event) do
    event
    |> Map.from_struct()
    |> Enum.flat_map(fn {field, value} ->
      generate_field_boundary_mutations(field, value, event_idx)
    end)
  end

  defp generate_event_boundary_mutations(_event, _event_idx), do: []

  defp generate_field_boundary_mutations(field, value, event_idx) when is_number(value) do
    base_mutations = [
      Operator.new_mutation(:boundary,
        type: :zero,
        target: field,
        original: value,
        mutated: 0,
        description: "Set to zero"
      ),
      Operator.new_mutation(:boundary,
        type: :negative,
        target: field,
        original: value,
        mutated: -1,
        description: "Set to negative"
      ),
      Operator.new_mutation(:boundary,
        type: :max_int,
        target: field,
        original: value,
        mutated: @max_int,
        description: "Set to max int"
      ),
      Operator.new_mutation(:boundary,
        type: :null,
        target: field,
        original: value,
        mutated: nil,
        description: "Set to nil"
      )
    ]

    # Add min_int for non-negative values
    mutations =
      if value >= 0 do
        base_mutations ++
          [
            Operator.new_mutation(:boundary,
              type: :min_int,
              target: field,
              original: value,
              mutated: @min_int,
              description: "Set to min int"
            )
          ]
      else
        base_mutations
      end

    Enum.map(mutations, &Map.put(&1, :event_index, event_idx))
  end

  defp generate_field_boundary_mutations(field, value, event_idx) when is_binary(value) do
    mutations = [
      Operator.new_mutation(:boundary,
        type: :empty_string,
        target: field,
        original: value,
        mutated: "",
        description: "Set to empty string"
      ),
      Operator.new_mutation(:boundary,
        type: :whitespace,
        target: field,
        original: value,
        mutated: "   ",
        description: "Set to whitespace only"
      ),
      Operator.new_mutation(:boundary,
        type: :null,
        target: field,
        original: value,
        mutated: nil,
        description: "Set to nil"
      )
    ]

    # Add very_long mutation for non-empty strings
    mutations =
      if String.length(value) > 0 and String.length(value) < 1000 do
        mutations ++
          [
            Operator.new_mutation(:boundary,
              type: :very_long,
              target: field,
              original: value,
              mutated: @long_string,
              description: "Set to very long string"
            )
          ]
      else
        mutations
      end

    Enum.map(mutations, &Map.put(&1, :event_index, event_idx))
  end

  defp generate_field_boundary_mutations(field, value, event_idx)
       when is_atom(value) and not is_nil(value) and not is_boolean(value) do
    [
      Operator.new_mutation(:boundary,
        type: :null,
        target: field,
        original: value,
        mutated: nil,
        description: "Set to nil"
      )
      |> Map.put(:event_index, event_idx)
    ]
  end

  defp generate_field_boundary_mutations(_field, _value, _event_idx), do: []

  defp truncate(str) when is_binary(str) do
    if String.length(str) > 20 do
      String.slice(str, 0, 20) <> "..."
    else
      str
    end
  end

  defp truncate(other), do: inspect(other)
end
