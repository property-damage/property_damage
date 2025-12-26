defmodule PropertyDamage.Mutation.Operators.Value do
  @moduledoc """
  Mutation operator that mutates numeric and string values in events.

  ## Mutation Types

  For numbers:
  - `:zero` - Replace with 0
  - `:negate` - Negate the value
  - `:increment` - Add 1
  - `:decrement` - Subtract 1
  - `:double` - Multiply by 2
  - `:halve` - Divide by 2

  For strings:
  - `:empty` - Replace with empty string
  - `:swap_case` - Swap case of first character
  - `:truncate` - Remove last character
  - `:append` - Append extra character

  For atoms:
  - `:swap` - Replace with a different common atom
  """

  @behaviour PropertyDamage.Mutation.Operator

  alias PropertyDamage.Mutation.Operator

  @impl true
  def name, do: :value

  @impl true
  def description, do: "Mutates numeric and string values in event fields"

  @impl true
  def generate_mutations(events, opts \\ []) do
    max_mutations = Keyword.get(opts, :max_mutations, 10)

    events
    |> Enum.flat_map(&extract_mutable_fields/1)
    |> Enum.flat_map(&generate_field_mutations/1)
    |> Enum.take(max_mutations)
  end

  @impl true
  def apply_mutation(events, mutation) do
    %{target: target, event_index: event_idx, mutated: mutated_value} = mutation

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      if idx == event_idx do
        apply_field_mutation(event, target, mutated_value)
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
      :negate -> "#{target}: #{original} → #{mutated}"
      :increment -> "#{target}: #{original} → #{original + 1}"
      :decrement -> "#{target}: #{original} → #{original - 1}"
      :double -> "#{target}: #{original} → #{original * 2}"
      :halve -> "#{target}: #{original} → #{mutated}"
      :empty -> "#{target}: \"#{original}\" → \"\""
      :swap_case -> "#{target}: \"#{original}\" → \"#{mutated}\""
      :truncate -> "#{target}: \"#{original}\" → \"#{mutated}\""
      :append -> "#{target}: \"#{original}\" → \"#{mutated}\""
      :swap_atom -> "#{target}: :#{original} → :#{mutated}"
      _ -> "#{target}: #{inspect(original)} → #{inspect(mutated)}"
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp extract_mutable_fields(event) when is_struct(event) do
    event
    |> Map.from_struct()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{field, value}, _} ->
      if mutable_value?(value) do
        [{event, field, value}]
      else
        []
      end
    end)
  end

  defp extract_mutable_fields(_), do: []

  defp mutable_value?(value) when is_number(value), do: true
  defp mutable_value?(value) when is_binary(value), do: true
  defp mutable_value?(value) when is_atom(value) and not is_nil(value), do: true
  defp mutable_value?(_), do: false

  defp generate_field_mutations({_event, field, value}) when is_number(value) do
    # We'll adjust this during application
    event_idx = 0

    mutations = [
      Operator.new_mutation(:value,
        type: :zero,
        target: field,
        original: value,
        mutated: 0,
        description: "Replace with zero"
      ),
      Operator.new_mutation(:value,
        type: :negate,
        target: field,
        original: value,
        mutated: -value,
        description: "Negate value"
      ),
      Operator.new_mutation(:value,
        type: :increment,
        target: field,
        original: value,
        mutated: value + 1,
        description: "Off-by-one (increment)"
      ),
      Operator.new_mutation(:value,
        type: :decrement,
        target: field,
        original: value,
        mutated: value - 1,
        description: "Off-by-one (decrement)"
      )
    ]

    # Add double/halve for non-zero values
    mutations =
      if value != 0 do
        mutations ++
          [
            Operator.new_mutation(:value,
              type: :double,
              target: field,
              original: value,
              mutated: value * 2,
              description: "Double value"
            ),
            Operator.new_mutation(:value,
              type: :halve,
              target: field,
              original: value,
              mutated: div_or_divide(value, 2),
              description: "Halve value"
            )
          ]
      else
        mutations
      end

    Enum.map(mutations, &Map.put(&1, :event_index, event_idx))
  end

  defp generate_field_mutations({_event, field, value}) when is_binary(value) do
    event_idx = 0

    mutations = [
      Operator.new_mutation(:value,
        type: :empty,
        target: field,
        original: value,
        mutated: "",
        description: "Replace with empty string"
      )
    ]

    # Add string-specific mutations for non-empty strings
    mutations =
      if String.length(value) > 0 do
        first_char = String.first(value)

        swapped_case =
          if first_char == String.upcase(first_char),
            do: String.downcase(first_char),
            else: String.upcase(first_char)

        swapped = swapped_case <> String.slice(value, 1..-1//1)

        mutations ++
          [
            Operator.new_mutation(:value,
              type: :swap_case,
              target: field,
              original: value,
              mutated: swapped,
              description: "Swap case of first character"
            ),
            Operator.new_mutation(:value,
              type: :truncate,
              target: field,
              original: value,
              mutated: String.slice(value, 0..-2//1),
              description: "Remove last character"
            ),
            Operator.new_mutation(:value,
              type: :append,
              target: field,
              original: value,
              mutated: value <> "X",
              description: "Append extra character"
            )
          ]
      else
        mutations
      end

    Enum.map(mutations, &Map.put(&1, :event_index, event_idx))
  end

  defp generate_field_mutations({_event, field, value}) when is_atom(value) do
    event_idx = 0

    # Common atom swaps
    swaps = %{
      true => false,
      false => true,
      :ok => :error,
      :error => :ok,
      :success => :failure,
      :failure => :success,
      :active => :inactive,
      :inactive => :active,
      :pending => :completed,
      :completed => :pending,
      :open => :closed,
      :closed => :open,
      :USD => :EUR,
      :EUR => :USD
    }

    case Map.get(swaps, value) do
      nil ->
        []

      swapped ->
        [
          Operator.new_mutation(:value,
            type: :swap_atom,
            target: field,
            original: value,
            mutated: swapped,
            description: "Swap atom value"
          )
          |> Map.put(:event_index, event_idx)
        ]
    end
  end

  defp generate_field_mutations(_), do: []

  defp apply_field_mutation(event, field, value) when is_struct(event) do
    if Map.has_key?(event, field) do
      Map.put(event, field, value)
    else
      event
    end
  end

  defp apply_field_mutation(event, _field, _value), do: event

  defp div_or_divide(value, divisor) when is_integer(value), do: div(value, divisor)
  defp div_or_divide(value, divisor) when is_float(value), do: value / divisor
end
