defmodule PropertyDamage.PlaceholderRegistry do
  @moduledoc false
  # Internal module for tracking and resolving placeholders.
  #
  # The registry maintains two indexes (DR-021):
  # - `placeholders`: Map from placeholder ID to placeholder struct. This is
  #   what transports from generation to execution; consumer resolution is by id.
  # - `producer_link`: Map from structured producer position to the placeholder
  #   IDs that command produces. The capture bridge used at execution time; it
  #   is keyed by position, but the position index is rebuilt per run (and
  #   remapped through shrinking), never resolved against a stale generation key.

  alias PropertyDamage.External
  alias PropertyDamage.Placeholder

  @typedoc """
  Registry for tracking placeholders throughout sequence execution.
  """
  @type t :: %__MODULE__{
          placeholders: %{Placeholder.id() => Placeholder.t()},
          producer_link: %{Placeholder.position() => [Placeholder.id()]}
        }

  defstruct placeholders: %{}, producer_link: %{}

  @doc """
  Create a new empty registry.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Build a registry from a list of items (commands) carrying placeholders.

  Collects every `%Placeholder{}` reachable in the items, de-duplicates by id,
  and registers each. Linear sequences carry `{:prefix, index}` positions, so the
  registry's `producer_link` maps each producer position to the ids it produces
  for `capture/3`.
  """
  @spec build([term()]) :: t()
  def build(items) when is_list(items) do
    items
    |> Enum.flat_map(&collect_placeholders/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(new(), &register(&2, &1))
  end

  @doc """
  Register a placeholder in the registry.

  Returns the updated registry.
  """
  @spec register(t(), Placeholder.t()) :: t()
  def register(%__MODULE__{} = reg, %Placeholder{} = p) do
    reg
    |> Map.update!(:placeholders, &Map.put(&1, p.id, p))
    |> index_by_position(p)
  end

  # Index by structured producer position (DR-021).
  defp index_by_position(reg, %Placeholder{position: nil}), do: reg

  defp index_by_position(reg, %Placeholder{position: position, id: id}) do
    Map.update!(reg, :producer_link, fn link ->
      Map.update(link, position, [id], &(&1 ++ [id]))
    end)
  end

  @doc """
  Get the placeholder IDs produced at a structured position (DR-021).
  """
  @spec ids_at_position(t(), Placeholder.position()) :: [reference()]
  def ids_at_position(%__MODULE__{} = reg, position) do
    Map.get(reg.producer_link, position, [])
  end

  @doc """
  Resolve a placeholder by its ID with a concrete value (DR-021).

  Returns the registry unchanged if no placeholder has that ID. This is the
  id-based write that execution-time capture uses, paired with `ids_at_position/2`.
  """
  @spec resolve(t(), reference(), term()) :: t()
  def resolve(%__MODULE__{} = reg, id, value) do
    case Map.get(reg.placeholders, id) do
      nil -> reg
      p -> %{reg | placeholders: Map.put(reg.placeholders, id, Placeholder.resolve(p, value))}
    end
  end

  @doc """
  Capture real external values produced at a structured `position` (DR-021).

  For each placeholder the producer at `position` mints (looked up via
  `ids_at_position/2`), reads the value at its recorded `path`/`event_index` in
  the command's real (adapter-returned) `events` and resolves it by id. This is
  position-driven, so it is correct under branching (distinct branch positions)
  and shrinking (the position is rebuilt per run, never a stale generation key).

  Returns the registry unchanged when `position` is `nil`.
  """
  @spec capture(t(), Placeholder.position() | nil, [struct()]) :: t()
  def capture(%__MODULE__{} = reg, nil, _events), do: reg

  def capture(%__MODULE__{} = reg, position, events) do
    reg
    |> ids_at_position(position)
    |> Enum.reduce(reg, fn id, acc ->
      case get(acc, id) do
        %Placeholder{path: path, event_index: event_index} ->
          case Enum.at(events, event_index) do
            event when is_struct(event) ->
              resolve(acc, id, External.get_at_path(event, path))

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  @doc """
  Get a placeholder by its ID.
  """
  @spec get(t(), reference()) :: Placeholder.t() | nil
  def get(%__MODULE__{} = reg, id) do
    Map.get(reg.placeholders, id)
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
                "(position #{inspect(p.position)}, event #{p.event_index})"

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
  Deep-resolve like `deep_resolve/2`, but return `{:ok, resolved}` or
  `{:error, message}` instead of raising when a placeholder is unresolved.

  Used by execution paths that must turn an unresolved consumer (for example, a
  producer command that errored before capturing its external) into a graceful
  error result rather than crashing the run.
  """
  @spec resolve_data(t(), term()) :: {:ok, term()} | {:error, String.t()}
  def resolve_data(%__MODULE__{} = reg, data) do
    {:ok, deep_resolve(reg, data)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

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
  Collect all `Placeholder` structs reachable in a data structure.

  Used by the consumer-routing affordance to surface the externals available
  in projection state to command generators (DR-021). Order is depth-first as
  encountered; duplicates (same id) are removed keeping the first.
  """
  @spec collect_placeholders(term()) :: [Placeholder.t()]
  def collect_placeholders(data) do
    data
    |> do_collect_placeholders([])
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.id)
  end

  defp do_collect_placeholders(%Placeholder{} = p, acc), do: [p | acc]

  defp do_collect_placeholders(%{__struct__: _} = struct, acc) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(acc, &do_collect_placeholders/2)
  end

  defp do_collect_placeholders(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, a ->
      a |> then(&do_collect_placeholders(k, &1)) |> then(&do_collect_placeholders(v, &1))
    end)
  end

  defp do_collect_placeholders(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_collect_placeholders/2)
  end

  defp do_collect_placeholders(tuple, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &do_collect_placeholders/2)
  end

  defp do_collect_placeholders(_, acc), do: acc

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
end
