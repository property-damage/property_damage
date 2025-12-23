defmodule PropertyDamage.Shrinker.Graph do
  @moduledoc """
  Dependency graph for command sequences.

  Builds and analyzes a directed acyclic graph (DAG) representing dependencies
  between commands in a sequence. Commands that produce refs are connected to
  commands that consume those refs.

  Used by the shrinker to identify independent subgraphs that can be safely
  removed without breaking ref resolution.

  ## Graph Structure

  - **Nodes**: Each command in the sequence is a node, identified by its index
  - **Edges**: An edge from node A to node B means B depends on A (B consumes
    a ref that A produces)
  - **Producers**: Map from ref identity to producing node index
  - **Consumers**: Map from node index to list of ref identities it consumes

  ## Example

  Given a sequence:
  ```
  0: CreateOrder (produces order_ref)
  1: AddItem (consumes order_ref, produces item_ref)
  2: ViewOrder (consumes order_ref)
  3: ProcessItem (consumes item_ref)
  ```

  The graph has edges:
  - 0 → 1 (order_ref)
  - 0 → 2 (order_ref)
  - 1 → 3 (item_ref)

  Node 3 cannot be kept without nodes 1 and 0.
  Node 2 can be removed independently of nodes 1 and 3.
  """

  alias PropertyDamage.Ref

  @typedoc """
  Dependency graph structure.
  """
  @type t :: %__MODULE__{
          nodes: MapSet.t(non_neg_integer()),
          edges: %{non_neg_integer() => MapSet.t(non_neg_integer())},
          producers: %{reference() => non_neg_integer()},
          consumers: %{non_neg_integer() => [reference()]}
        }

  defstruct nodes: MapSet.new(),
            edges: %{},
            producers: %{},
            consumers: %{}

  @doc """
  Build a dependency graph from a command sequence.

  Analyzes each command to find refs it produces (via creates_ref/0) and
  refs it consumes (any Ref structs in its fields).

  ## Parameters

  - `commands` - List of command structs

  ## Returns

  A dependency graph with nodes, edges, producers, and consumers.

  ## Example

      commands = [%CreateOrder{ref: ref1}, %AddItem{order: ref1, ref: ref2}]
      graph = Graph.build(commands)
  """
  @spec build([struct()]) :: t()
  def build(commands) do
    # First pass: identify producers
    {producers, _} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {command, index}, {prods, _consumers} ->
        case find_produced_ref(command) do
          nil -> {prods, %{}}
          ref_id -> {Map.put(prods, ref_id, index), %{}}
        end
      end)

    # Second pass: identify consumers and build edges
    {nodes, edges, consumers} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), %{}, %{}}, fn {command, index}, {nodes, edges, consumers} ->
        # Get refs consumed, excluding the ref this command produces
        produced_ref_field = get_produced_ref_field(command)
        refs_consumed = find_consumed_refs(command, produced_ref_field)
        nodes = MapSet.put(nodes, index)
        consumers = Map.put(consumers, index, refs_consumed)

        # Create edges from producer to consumer
        edges =
          Enum.reduce(refs_consumed, edges, fn ref_id, acc ->
            case Map.get(producers, ref_id) do
              nil ->
                acc

              producer_index ->
                existing = Map.get(acc, producer_index, MapSet.new())
                Map.put(acc, producer_index, MapSet.put(existing, index))
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

  # Find the ref produced by a command (if any)
  defp find_produced_ref(command) do
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      case command_module.creates_ref() do
        nil ->
          nil

        ref_field ->
          case Map.get(command, ref_field) do
            %Ref{ref: ref_id} -> ref_id
            _ -> nil
          end
      end
    else
      nil
    end
  end

  # Get the field name that holds the produced ref (if any)
  defp get_produced_ref_field(command) do
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      command_module.creates_ref()
    else
      nil
    end
  end

  # Find all refs consumed by a command, excluding the produced ref field
  defp find_consumed_refs(command, exclude_field) do
    command
    |> Map.from_struct()
    |> Map.delete(exclude_field)
    |> collect_refs([])
    |> Enum.uniq()
  end

  defp collect_refs(%Ref{ref: ref_id}, acc), do: [ref_id | acc]

  # Skip other structs (like DateTime) - they don't contain refs
  defp collect_refs(%{__struct__: _}, acc), do: acc

  defp collect_refs(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_k, v}, a -> collect_refs(v, a) end)
  end

  defp collect_refs(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn v, a -> collect_refs(v, a) end)
  end

  defp collect_refs(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_refs(acc)
  end

  defp collect_refs(_other, acc), do: acc

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
