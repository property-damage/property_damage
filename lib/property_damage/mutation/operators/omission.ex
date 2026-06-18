defmodule PropertyDamage.Mutation.Operators.Omission do
  @moduledoc false

  @behaviour PropertyDamage.Mutation.Operator

  alias PropertyDamage.Mutation.Operator

  @impl true
  def name, do: :omission

  @impl true
  def description, do: "Removes fields from events to test presence validation"

  @impl true
  def generate_mutations(events, opts \\ []) do
    max_mutations = Keyword.get(opts, :max_mutations, 10)

    field_mutations = generate_field_omissions(events)
    event_mutations = generate_event_omissions(events)

    (field_mutations ++ event_mutations)
    |> Enum.take(max_mutations)
  end

  @impl true
  def apply_mutation(events, mutation) do
    case mutation.type do
      :remove_field ->
        apply_field_removal(events, mutation)

      :remove_event ->
        apply_event_removal(events, mutation)
    end
  end

  @impl true
  def describe_mutation(mutation) do
    case mutation.type do
      :remove_field ->
        "Removed field '#{mutation.target}' from event at index #{mutation.event_index}"

      :remove_event ->
        "Removed event at index #{mutation.event_index}"
    end
  end

  # ============================================================================
  # Field Omission
  # ============================================================================

  defp generate_field_omissions(events) do
    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, event_idx} ->
      if is_struct(event) do
        event
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.map(fn field ->
          Operator.new_mutation(:omission,
            type: :remove_field,
            target: field,
            original: Map.get(event, field),
            mutated: nil,
            description: "Remove field #{field}"
          )
          |> Map.put(:event_index, event_idx)
          |> Map.put(:event_type, event.__struct__)
        end)
      else
        []
      end
    end)
  end

  defp apply_field_removal(events, mutation) do
    %{event_index: event_idx, target: field} = mutation

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      if idx == event_idx and is_struct(event) do
        # Create a map without the field, then create a new struct
        # This simulates the field being missing from the response
        event
        |> Map.from_struct()
        |> Map.delete(field)
        |> then(fn fields ->
          # Re-create struct with nil for the removed field
          struct(event.__struct__, Map.put(fields, field, nil))
        end)
      else
        event
      end
    end)
  end

  # ============================================================================
  # Event Omission
  # ============================================================================

  defp generate_event_omissions(events) do
    if length(events) <= 1 do
      # Don't generate event omissions if there's only one event
      []
    else
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, event_idx} ->
        event_type = if is_struct(event), do: event.__struct__, else: nil

        Operator.new_mutation(:omission,
          type: :remove_event,
          target: :event,
          original: event_type,
          mutated: nil,
          description: "Remove event #{inspect(event_type)}"
        )
        |> Map.put(:event_index, event_idx)
        |> Map.put(:event_type, event_type)
      end)
    end
  end

  defp apply_event_removal(events, mutation) do
    %{event_index: event_idx} = mutation

    events
    |> Enum.with_index()
    |> Enum.reject(fn {_event, idx} -> idx == event_idx end)
    |> Enum.map(fn {event, _idx} -> event end)
  end
end
