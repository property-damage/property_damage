defmodule PropertyDamage.PlaceholderRegistry do
  @moduledoc false
  # Internal module for tracking and resolving placeholders.
  #
  # The registry maintains two indexes:
  # - `placeholders`: Map from placeholder ID to placeholder struct
  # - `by_location`: Map from location key to placeholder ID
  #
  # This dual indexing enables:
  # - Fast lookup by ID during deep_resolve
  # - Fast lookup by location during resolution from real events

  alias PropertyDamage.Placeholder

  @typedoc """
  Registry for tracking placeholders throughout sequence execution.
  """
  @type t :: %__MODULE__{
          placeholders: %{reference() => Placeholder.t()},
          by_location: %{
            {module(), [atom() | non_neg_integer()], non_neg_integer(), non_neg_integer()} =>
              reference()
          }
        }

  defstruct placeholders: %{}, by_location: %{}

  @doc """
  Create a new empty registry.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Register a placeholder in the registry.

  Returns the updated registry.
  """
  @spec register(t(), Placeholder.t()) :: t()
  def register(%__MODULE__{} = reg, %Placeholder{} = p) do
    location = Placeholder.location_key(p)

    %{
      reg
      | placeholders: Map.put(reg.placeholders, p.id, p),
        by_location: Map.put(reg.by_location, location, p.id)
    }
  end

  @doc """
  Resolve a placeholder by its location with a concrete value.

  Location is identified by: event_module, path, command_index, event_index.

  Returns the updated registry. If no placeholder exists at the location,
  returns the registry unchanged.
  """
  @spec resolve_by_location(
          t(),
          module(),
          [atom() | non_neg_integer()],
          non_neg_integer(),
          non_neg_integer(),
          term()
        ) :: t()
  def resolve_by_location(reg, event_module, path, cmd_idx, evt_idx, value) do
    location = {event_module, path, cmd_idx, evt_idx}

    case Map.get(reg.by_location, location) do
      nil ->
        reg

      id ->
        placeholder = Map.fetch!(reg.placeholders, id)
        resolved = Placeholder.resolve(placeholder, value)
        %{reg | placeholders: Map.put(reg.placeholders, id, resolved)}
    end
  end

  @doc """
  Get a placeholder by its ID.
  """
  @spec get(t(), reference()) :: Placeholder.t() | nil
  def get(%__MODULE__{} = reg, id) do
    Map.get(reg.placeholders, id)
  end

  @doc """
  Get a placeholder by its location.
  """
  @spec get_by_location(
          t(),
          module(),
          [atom() | non_neg_integer()],
          non_neg_integer(),
          non_neg_integer()
        ) :: Placeholder.t() | nil
  def get_by_location(reg, event_module, path, cmd_idx, evt_idx) do
    location = {event_module, path, cmd_idx, evt_idx}

    case Map.get(reg.by_location, location) do
      nil -> nil
      id -> Map.get(reg.placeholders, id)
    end
  end

  @doc """
  Deep-resolve all placeholders in a data structure.

  Traverses the data structure and replaces any Placeholder structs with
  their resolved values. Raises if any placeholder is unresolved.

  ## Example

      # After placeholders are resolved in the registry:
      resolved_event = PlaceholderRegistry.deep_resolve(registry, event_with_placeholders)
  """
  @spec deep_resolve(t(), term()) :: term()
  def deep_resolve(%__MODULE__{} = reg, data) do
    do_deep_resolve(reg, data)
  end

  defp do_deep_resolve(reg, %Placeholder{id: id}) do
    case Map.get(reg.placeholders, id) do
      nil ->
        raise ArgumentError, "Unknown placeholder ID: #{inspect(id)}"

      %{resolved: nil} = p ->
        raise ArgumentError,
              "Unresolved placeholder at #{inspect(p.path)} " <>
                "(command #{p.command_index}, event #{p.event_index})"

      %{resolved: value} ->
        value
    end
  end

  defp do_deep_resolve(reg, %{__struct__: mod} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, do_deep_resolve(reg, v)} end)
    |> then(&struct!(mod, &1))
  end

  defp do_deep_resolve(reg, map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {do_deep_resolve(reg, k), do_deep_resolve(reg, v)}
    end)
  end

  defp do_deep_resolve(reg, list) when is_list(list) do
    Enum.map(list, &do_deep_resolve(reg, &1))
  end

  defp do_deep_resolve(reg, tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&do_deep_resolve(reg, &1))
    |> List.to_tuple()
  end

  defp do_deep_resolve(_reg, value), do: value

  @doc """
  Check if a data structure contains any placeholders.

  Useful for validation before executing commands.
  """
  @spec contains_placeholder?(term()) :: boolean()
  def contains_placeholder?(%Placeholder{}), do: true

  def contains_placeholder?(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&contains_placeholder?/1)
  end

  def contains_placeholder?(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.any?(&contains_placeholder?/1)
  end

  def contains_placeholder?(list) when is_list(list) do
    Enum.any?(list, &contains_placeholder?/1)
  end

  def contains_placeholder?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&contains_placeholder?/1)
  end

  def contains_placeholder?(_), do: false

  @doc """
  Collect all placeholder IDs from a data structure.

  Returns a list of placeholder IDs found in the structure.
  """
  @spec collect_placeholder_ids(term()) :: [reference()]
  def collect_placeholder_ids(data) do
    do_collect_ids(data, [])
    |> Enum.uniq()
  end

  defp do_collect_ids(%Placeholder{id: id}, acc), do: [id | acc]

  defp do_collect_ids(%{__struct__: _} = struct, acc) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(acc, fn elem, a -> do_collect_ids(elem, a) end)
  end

  defp do_collect_ids(map, acc) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.reduce(acc, fn {k, v}, a ->
      a
      |> then(&do_collect_ids(k, &1))
      |> then(&do_collect_ids(v, &1))
    end)
  end

  defp do_collect_ids(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn elem, a -> do_collect_ids(elem, a) end)
  end

  defp do_collect_ids(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, fn elem, a -> do_collect_ids(elem, a) end)
  end

  defp do_collect_ids(_, acc), do: acc

  @doc """
  Get all placeholders in the registry.
  """
  @spec all(t()) :: [Placeholder.t()]
  def all(%__MODULE__{} = reg) do
    Map.values(reg.placeholders)
  end

  @doc """
  Get all resolved placeholders.
  """
  @spec resolved(t()) :: [Placeholder.t()]
  def resolved(%__MODULE__{} = reg) do
    reg.placeholders
    |> Map.values()
    |> Enum.filter(&Placeholder.resolved?/1)
  end

  @doc """
  Get all unresolved placeholders.
  """
  @spec unresolved(t()) :: [Placeholder.t()]
  def unresolved(%__MODULE__{} = reg) do
    reg.placeholders
    |> Map.values()
    |> Enum.reject(&Placeholder.resolved?/1)
  end

  @doc """
  Build a map from placeholder ID to producing command index.

  Useful for building dependency graphs.
  """
  @spec producers(t()) :: %{reference() => non_neg_integer()}
  def producers(%__MODULE__{} = reg) do
    reg.placeholders
    |> Enum.map(fn {id, p} -> {id, p.command_index} end)
    |> Map.new()
  end
end
