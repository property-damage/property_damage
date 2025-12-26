defmodule PropertyDamage.Mutation.Operators.Event do
  @moduledoc """
  Mutation operator that modifies event contents.

  Tests whether checks properly validate event data and relationships.

  ## Mutation Types

  - `:wrong_ref` - Replace a ref/id with a different value
  - `:duplicate_event` - Duplicate an event
  - `:reorder_events` - Swap order of two events
  - `:wrong_type` - Change event type (if possible)
  """

  @behaviour PropertyDamage.Mutation.Operator

  alias PropertyDamage.Mutation.Operator

  @impl true
  def name, do: :event

  @impl true
  def description, do: "Modifies event contents and structure"

  @impl true
  def generate_mutations(events, opts \\ []) do
    max_mutations = Keyword.get(opts, :max_mutations, 10)

    ref_mutations = generate_ref_mutations(events)
    structure_mutations = generate_structure_mutations(events)

    (ref_mutations ++ structure_mutations)
    |> Enum.take(max_mutations)
  end

  @impl true
  def apply_mutation(events, mutation) do
    case mutation.type do
      :wrong_ref ->
        apply_wrong_ref(events, mutation)

      :duplicate_event ->
        apply_duplicate_event(events, mutation)

      :reorder_events ->
        apply_reorder_events(events, mutation)

      _ ->
        events
    end
  end

  @impl true
  def describe_mutation(mutation) do
    case mutation.type do
      :wrong_ref ->
        "Changed #{mutation.target} from #{inspect(mutation.original)} to #{inspect(mutation.mutated)}"

      :duplicate_event ->
        "Duplicated event at index #{mutation.event_index}"

      :reorder_events ->
        "Swapped events at indices #{mutation.event_index} and #{mutation.swap_index}"

      _ ->
        inspect(mutation)
    end
  end

  # ============================================================================
  # Ref Mutations
  # ============================================================================

  defp generate_ref_mutations(events) do
    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, event_idx} ->
      if is_struct(event) do
        event
        |> Map.from_struct()
        |> Enum.filter(fn {key, value} ->
          is_ref_field?(key) and not is_nil(value)
        end)
        |> Enum.map(fn {field, value} ->
          Operator.new_mutation(:event,
            type: :wrong_ref,
            target: field,
            original: value,
            mutated: mutate_ref_value(value),
            description: "Replace ref with wrong value"
          )
          |> Map.put(:event_index, event_idx)
        end)
      else
        []
      end
    end)
  end

  defp is_ref_field?(key) do
    key_str = to_string(key)

    String.ends_with?(key_str, "_ref") or
      String.ends_with?(key_str, "_id") or
      key == :id or
      key == :ref
  end

  defp mutate_ref_value(value) when is_binary(value) do
    # Append "_wrong" to make it clearly different
    value <> "_wrong"
  end

  defp mutate_ref_value(value) when is_integer(value) do
    # Use a different integer
    value + 999_999
  end

  defp mutate_ref_value(value) when is_atom(value) do
    # Create a different atom
    String.to_atom("wrong_#{value}")
  end

  defp mutate_ref_value(value), do: value

  defp apply_wrong_ref(events, mutation) do
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

  # ============================================================================
  # Structure Mutations
  # ============================================================================

  defp generate_structure_mutations(events) do
    duplicate_mutations =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, event_idx} ->
        event_type = if is_struct(event), do: event.__struct__, else: nil

        Operator.new_mutation(:event,
          type: :duplicate_event,
          target: :event,
          original: 1,
          mutated: 2,
          description: "Duplicate event"
        )
        |> Map.put(:event_index, event_idx)
        |> Map.put(:event_type, event_type)
      end)

    reorder_mutations =
      if length(events) >= 2 do
        # Generate one swap mutation for adjacent events
        [
          Operator.new_mutation(:event,
            type: :reorder_events,
            target: :order,
            original: "0,1",
            mutated: "1,0",
            description: "Swap first two events"
          )
          |> Map.put(:event_index, 0)
          |> Map.put(:swap_index, 1)
        ]
      else
        []
      end

    duplicate_mutations ++ reorder_mutations
  end

  defp apply_duplicate_event(events, mutation) do
    %{event_index: event_idx} = mutation

    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, idx} ->
      if idx == event_idx do
        [event, event]
      else
        [event]
      end
    end)
  end

  defp apply_reorder_events(events, mutation) do
    %{event_index: idx1, swap_index: idx2} = mutation

    if idx1 < length(events) and idx2 < length(events) do
      events
      |> List.update_at(idx1, fn _ -> Enum.at(events, idx2) end)
      |> List.update_at(idx2, fn _ -> Enum.at(events, idx1) end)
    else
      events
    end
  end
end
