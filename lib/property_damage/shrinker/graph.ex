defmodule PropertyDamage.Shrinker.Graph do
  @moduledoc false

  alias PropertyDamage.Placeholder
  alias PropertyDamage.Sequence.Position

  @typedoc """
  Dependency graph structure.

  Producer/consumer keys are `{:placeholder, reference()}` dependency
  identities.
  """
  @type t :: %__MODULE__{
          nodes: MapSet.t(non_neg_integer()),
          edges: %{non_neg_integer() => MapSet.t(non_neg_integer())},
          producers: %{{:placeholder, reference()} => non_neg_integer()},
          consumers: %{non_neg_integer() => [{:placeholder, reference()}]}
        }

  defstruct nodes: MapSet.new(),
            edges: %{},
            producers: %{},
            consumers: %{}

  @doc """
  Build a dependency graph from a command sequence.

  Analyzes each command to find the placeholders it consumes (any
  `%Placeholder{}` structs in its fields, DR-021). A placeholder's producer is
  identified by its structured `position`, not by which command embeds it.

  ## Parameters

  - `commands` - List of command structs

  ## Returns

  A dependency graph with nodes, edges, producers, and consumers.

  ## Example

      consumer = %AddItem{order: placeholder_for_index_0}
      graph = Graph.build([%CreateOrder{}, consumer])
  """
  @spec build([struct()]) :: t()
  def build(commands) do
    # Identify producers. A placeholder's producer is identified by its
    # structured position (DR-021); for the linear command list the graph
    # operates on, a prefix position's offset maps directly to index i.
    producers = add_placeholder_producers(commands, %{})

    # Identify consumers and build edges
    {nodes, edges, consumers} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), %{}, %{}}, fn {command, index}, {nodes, edges, consumers} ->
        deps_consumed = find_consumed_deps(command)
        nodes = MapSet.put(nodes, index)
        consumers = Map.put(consumers, index, deps_consumed)

        # Create edges from producer to consumer
        edges =
          Enum.reduce(deps_consumed, edges, fn dep_key, acc ->
            producer_index = Map.get(producers, dep_key)

            case producer_index do
              nil ->
                acc

              idx when idx == index ->
                # Don't create self-edges
                acc

              idx ->
                existing = Map.get(acc, idx, MapSet.new())
                Map.put(acc, idx, MapSet.put(existing, index))
            end
          end)

        {nodes, edges, consumers}
      end)

    %__MODULE__{
      nodes: nodes,
      edges: edges,
      producers: producers,
      consumers: consumers
    }
  end

  # Scan all commands to find placeholders and record their producers
  defp add_placeholder_producers(commands, producers) do
    commands
    |> Enum.with_index()
    |> Enum.reduce(producers, fn {command, _index}, prods ->
      # Find all placeholders in this command
      placeholders = collect_placeholders(command)

      Enum.reduce(placeholders, prods, fn %Placeholder{} = p, acc ->
        Map.put(acc, {:placeholder, p.id}, placeholder_producer_index(p))
      end)
    end)
  end

  # The producing command's index for a placeholder, in the linear command-list
  # index space the graph uses. Non-prefix positions have no producer in this
  # space (nil → no dependency edge).
  defp placeholder_producer_index(%Placeholder{position: %Position{section: :prefix, offset: i}}),
    do: i

  defp placeholder_producer_index(%Placeholder{}), do: nil

  # Collect all Placeholder structs from a data structure
  defp collect_placeholders(data), do: do_collect_placeholders(data, [])

  defp do_collect_placeholders(%Placeholder{} = p, acc), do: [p | acc]

  defp do_collect_placeholders(%{__struct__: _} = struct, acc) do
    struct
    |> Map.from_struct()
    |> Map.values()
    |> Enum.reduce(acc, &do_collect_placeholders/2)
  end

  defp do_collect_placeholders(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_k, v}, a -> do_collect_placeholders(v, a) end)
  end

  defp do_collect_placeholders(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_collect_placeholders/2)
  end

  defp do_collect_placeholders(tuple, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &do_collect_placeholders/2)
  end

  defp do_collect_placeholders(_, acc), do: acc

  @doc """
  Get all ancestors of a node (transitive dependencies).

  Returns all nodes that must exist for the given node to be valid.
  This includes direct dependencies and their dependencies recursively.

  ## Example

      # If node 3 depends on 1, and 1 depends on 0
      ancestors = Graph.ancestors(graph, 3)
      # => MapSet.new([0, 1])
  """
  @spec ancestors(t(), non_neg_integer()) :: MapSet.t(non_neg_integer())
  def ancestors(graph, node) do
    do_ancestors(graph, node, MapSet.new())
  end

  defp do_ancestors(graph, node, visited) do
    if MapSet.member?(visited, node) do
      MapSet.new()
    else
      # Find nodes that have an edge TO this node (direct parents)
      direct_parents =
        graph.edges
        |> Enum.filter(fn {_from, to_set} -> MapSet.member?(to_set, node) end)
        |> Enum.map(fn {from, _} -> from end)
        |> MapSet.new()

      # Mark this node as visited to avoid cycles
      visited = MapSet.put(visited, node)

      # Include direct parents and recursively find their ancestors
      Enum.reduce(direct_parents, direct_parents, fn parent, acc ->
        MapSet.union(acc, do_ancestors(graph, parent, visited))
      end)
    end
  end

  @doc """
  Compress the graph into super-nodes grouped by depth from roots.

  Nodes at the same depth (same distance from root nodes) are grouped together.
  This enables hierarchical delta debugging where we try removing groups at
  the same level before drilling down.

  ## Returns

  List of lists, where each inner list contains node indices at that depth.
  Index 0 is root nodes (no dependencies), index 1 is nodes depending only
  on roots, etc.

  ## Example

      # Graph: 0 → 1 → 2, 0 → 3
      levels = Graph.compress(graph)
      # => [[0], [1, 3], [2]]
  """
  @spec compress(t()) :: [[non_neg_integer()]]
  def compress(graph) do
    depths = compute_depths(graph)

    depths
    |> Enum.group_by(fn {_node, depth} -> depth end)
    |> Enum.sort_by(fn {depth, _nodes} -> depth end)
    |> Enum.map(fn {_depth, nodes_with_depth} ->
      Enum.map(nodes_with_depth, fn {node, _} -> node end)
    end)
  end

  @doc """
  Topologically sort nodes by distance from roots.

  Returns nodes in order such that dependencies come before dependents.
  Ties are broken by original index.

  ## Example

      sorted = Graph.topo_sort_by_distance(graph)
      # => [0, 1, 3, 2]  # roots first, then by depth
  """
  @spec topo_sort_by_distance(t()) :: [non_neg_integer()]
  def topo_sort_by_distance(graph) do
    depths = compute_depths(graph)

    depths
    |> Enum.sort_by(fn {node, depth} -> {depth, node} end)
    |> Enum.map(fn {node, _} -> node end)
  end

  @doc """
  Expand a super-node (list of indices) to include all required ancestors.

  Given a set of nodes to keep, returns the minimal set that includes
  those nodes plus all their transitive dependencies.

  ## Example

      # Want to keep node 3, but it needs 1 and 0
      expanded = Graph.expand_super_node(graph, [3])
      # => [0, 1, 3]
  """
  @spec expand_super_node(t(), [non_neg_integer()]) :: [non_neg_integer()]
  def expand_super_node(graph, nodes) do
    all_needed =
      Enum.reduce(nodes, MapSet.new(nodes), fn node, acc ->
        MapSet.union(acc, ancestors(graph, node))
      end)

    all_needed
    |> MapSet.to_list()
    |> Enum.sort()
  end

  # Find all placeholder dependencies consumed by a command
  defp find_consumed_deps(command) do
    command
    |> Map.from_struct()
    |> collect_deps([])
    |> Enum.uniq()
  end

  # Collect placeholder dependencies - use the placeholder's id as the dependency key
  defp collect_deps(%Placeholder{id: id}, acc), do: [{:placeholder, id} | acc]

  # Skip other structs (like DateTime) - they don't contain placeholders
  defp collect_deps(%{__struct__: _}, acc), do: acc

  defp collect_deps(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_k, v}, a -> collect_deps(v, a) end)
  end

  defp collect_deps(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn v, a -> collect_deps(v, a) end)
  end

  defp collect_deps(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_deps(acc)
  end

  defp collect_deps(_other, acc), do: acc

  # Compute depth for each node (distance from roots)
  defp compute_depths(graph) do
    # Roots are nodes with no incoming edges
    all_targets =
      graph.edges
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    roots = MapSet.difference(graph.nodes, all_targets)

    # BFS from roots
    initial_depths = for root <- roots, into: %{}, do: {root, 0}

    bfs(graph, MapSet.to_list(roots), initial_depths, 0)
  end

  defp bfs(_graph, [], depths, _current_depth), do: depths

  defp bfs(graph, current_level, depths, current_depth) do
    next_level =
      current_level
      |> Enum.flat_map(fn node ->
        Map.get(graph.edges, node, MapSet.new()) |> MapSet.to_list()
      end)
      |> Enum.uniq()
      |> Enum.reject(fn node -> Map.has_key?(depths, node) end)

    new_depths =
      Enum.reduce(next_level, depths, fn node, acc ->
        Map.put(acc, node, current_depth + 1)
      end)

    bfs(graph, next_level, new_depths, current_depth + 1)
  end
end
