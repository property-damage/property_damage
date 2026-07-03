defmodule PropertyDamage.Shrinker.GraphTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.Placeholder
  alias PropertyDamage.Shrinker.Graph

  # In the external()/placeholder model (DR-021) a producing command holds
  # nothing special: the producer is identified by each *consumed* placeholder's
  # structured `position`. A consuming command embeds %Placeholder{} structs
  # whose `position` points at the producing command's index and whose `id` is
  # the dependency identity. These fixtures build that shape directly.
  defmodule Event do
    @moduledoc false
    defstruct [:id]
  end

  defmodule Command do
    @moduledoc false
    defstruct [:name, :data, :a, :b]
  end

  # A placeholder produced by the command at prefix index `i`.
  defp produced_at(i), do: Placeholder.new_at(Event, [:id], Position.prefix(i), 0)

  describe "build/1" do
    test "creates nodes for each command" do
      commands = [
        %Command{data: 1},
        %Command{data: 2},
        %Command{data: 3}
      ]

      graph = Graph.build(commands)

      assert MapSet.size(graph.nodes) == 3
      assert MapSet.member?(graph.nodes, 0)
      assert MapSet.member?(graph.nodes, 1)
      assert MapSet.member?(graph.nodes, 2)
    end

    test "tracks placeholder producers" do
      # Two producers (indices 0 and 1), both consumed by a later command so
      # their placeholders appear in the sequence and get indexed by position.
      p0 = produced_at(0)
      p1 = produced_at(1)

      commands = [
        %Command{name: "first"},
        %Command{name: "second"},
        %Command{name: "consumer", a: p0, b: p1}
      ]

      graph = Graph.build(commands)

      # Producers are keyed by {:placeholder, id}; the value is the producing
      # command's index, derived from the placeholder's position.
      assert Map.get(graph.producers, {:placeholder, p0.id}) == 0
      assert Map.get(graph.producers, {:placeholder, p1.id}) == 1
    end

    test "creates edges for consumers" do
      p = produced_at(0)

      commands = [
        %Command{name: "producer"},
        %Command{name: "consumer", a: p}
      ]

      graph = Graph.build(commands)

      # Node 0 (producer) should have edge to node 1 (consumer)
      edges_from_0 = Map.get(graph.edges, 0, MapSet.new())
      assert MapSet.member?(edges_from_0, 1)
    end

    test "tracks consumed placeholders per node" do
      p = produced_at(0)

      commands = [
        %Command{name: "producer"},
        %Command{name: "consumer", a: p}
      ]

      graph = Graph.build(commands)

      # Node 1 consumes the placeholder (consumers stores {:placeholder, id})
      assert {:placeholder, p.id} in Map.get(graph.consumers, 1, [])
    end

    test "handles complex dependency graph" do
      # Create: 0 → 1 → 2, 0 → 3
      p_a = produced_at(0)
      p_b = produced_at(1)

      commands = [
        # index 0, produces p_a
        %Command{name: "a"},
        # index 1, consumes p_a, produces p_b
        %Command{name: "b", a: p_a},
        # index 2, consumes p_b
        %Command{name: "c", a: p_b},
        # index 3, consumes p_a
        %Command{name: "d", a: p_a}
      ]

      graph = Graph.build(commands)

      # Check edges: 0 → 1, 0 → 3, 1 → 2
      assert MapSet.member?(Map.get(graph.edges, 0, MapSet.new()), 1)
      assert MapSet.member?(Map.get(graph.edges, 0, MapSet.new()), 3)
      assert MapSet.member?(Map.get(graph.edges, 1, MapSet.new()), 2)
    end
  end

  describe "ancestors/2" do
    test "returns empty set for root nodes" do
      commands = [
        %Command{data: 1},
        %Command{data: 2}
      ]

      graph = Graph.build(commands)
      ancestors = Graph.ancestors(graph, 0)

      assert MapSet.size(ancestors) == 0
    end

    test "returns direct dependencies" do
      p = produced_at(0)

      commands = [
        %Command{name: "producer"},
        %Command{name: "consumer", a: p}
      ]

      graph = Graph.build(commands)
      ancestors = Graph.ancestors(graph, 1)

      assert MapSet.member?(ancestors, 0)
    end

    test "returns transitive dependencies" do
      p_a = produced_at(0)
      p_b = produced_at(1)

      # 0 produces p_a
      # 1 consumes p_a, produces p_b
      # 2 consumes p_b
      commands = [
        %Command{name: "a"},
        %Command{name: "b", a: p_a},
        %Command{name: "c", a: p_b}
      ]

      graph = Graph.build(commands)
      ancestors = Graph.ancestors(graph, 2)

      # Node 2 depends on 1, which depends on 0
      assert MapSet.member?(ancestors, 0)
      assert MapSet.member?(ancestors, 1)
    end
  end

  describe "compress/1" do
    test "groups nodes by depth" do
      p = produced_at(0)

      commands = [
        # depth 0
        %Command{name: "root"},
        # depth 1
        %Command{name: "consumer", a: p},
        # depth 0 (no deps)
        %Command{data: "also_root"}
      ]

      graph = Graph.build(commands)
      levels = Graph.compress(graph)

      # Level 0: nodes 0 and 2 (roots)
      # Level 1: node 1 (depends on 0)
      assert length(levels) == 2

      level_0 = Enum.at(levels, 0)
      level_1 = Enum.at(levels, 1)

      assert 0 in level_0
      assert 2 in level_0
      assert 1 in level_1
    end

    test "handles deep chains" do
      p_a = produced_at(0)
      p_b = produced_at(1)
      p_c = produced_at(2)

      commands = [
        %Command{name: "a"},
        %Command{name: "b", a: p_a},
        %Command{name: "c", a: p_b},
        %Command{name: "d", a: p_c}
      ]

      graph = Graph.build(commands)
      levels = Graph.compress(graph)

      assert length(levels) == 4
      assert Enum.at(levels, 0) == [0]
      assert Enum.at(levels, 1) == [1]
      assert Enum.at(levels, 2) == [2]
      assert Enum.at(levels, 3) == [3]
    end
  end

  describe "topo_sort_by_distance/1" do
    test "returns nodes in dependency order" do
      p = produced_at(0)

      commands = [
        # index 0
        %Command{name: "a"},
        # index 1
        %Command{name: "b", a: p}
      ]

      graph = Graph.build(commands)
      sorted = Graph.topo_sort_by_distance(graph)

      # Producer should come before consumer
      producer_pos = Enum.find_index(sorted, &(&1 == 0))
      consumer_pos = Enum.find_index(sorted, &(&1 == 1))

      assert producer_pos < consumer_pos
    end

    test "handles independent nodes" do
      commands = [
        %Command{data: 1},
        %Command{data: 2},
        %Command{data: 3}
      ]

      graph = Graph.build(commands)
      sorted = Graph.topo_sort_by_distance(graph)

      # All at same depth, sorted by index
      assert sorted == [0, 1, 2]
    end
  end

  describe "expand_super_node/2" do
    test "includes node and its ancestors" do
      p = produced_at(0)

      commands = [
        %Command{name: "producer"},
        %Command{name: "consumer", a: p}
      ]

      graph = Graph.build(commands)

      # Want to keep node 1, must include node 0
      expanded = Graph.expand_super_node(graph, [1])

      assert 0 in expanded
      assert 1 in expanded
    end

    test "handles multiple nodes" do
      p_a = produced_at(0)
      p_b = produced_at(1)

      commands = [
        # 0
        %Command{name: "a"},
        # 1
        %Command{name: "b"},
        # 2 consumes p_a
        %Command{name: "c", a: p_a},
        # 3 consumes p_b
        %Command{name: "d", a: p_b}
      ]

      graph = Graph.build(commands)

      # Want to keep nodes 2 and 3
      expanded = Graph.expand_super_node(graph, [2, 3])

      # Need 0, 1, 2, 3
      assert 0 in expanded
      assert 1 in expanded
      assert 2 in expanded
      assert 3 in expanded
    end

    test "returns sorted list" do
      p = produced_at(0)

      commands = [
        %Command{name: "producer"},
        %Command{name: "consumer", a: p}
      ]

      graph = Graph.build(commands)
      expanded = Graph.expand_super_node(graph, [1])

      assert expanded == [0, 1]
    end
  end

  describe "simple DAG structure" do
    test "diamond dependency pattern" do
      # Pattern:    0
      #           /   \
      #          1     2
      #           \   /
      #             3
      p_root = produced_at(0)
      p_left = produced_at(1)
      p_right = produced_at(2)

      commands = [
        # 0
        %Command{name: "root"},
        # 1 consumes root, produces left
        %Command{name: "left", a: p_root},
        # 2 consumes root, produces right
        %Command{name: "right", a: p_root},
        # 3 consumes left and right
        %Command{name: "d", a: p_left, b: p_right}
      ]

      graph = Graph.build(commands)

      # Node 0 should have edges to 1 and 2
      edges_from_0 = Map.get(graph.edges, 0, MapSet.new())
      assert MapSet.member?(edges_from_0, 1)
      assert MapSet.member?(edges_from_0, 2)

      # Ancestors of node 1 should be just 0
      ancestors_1 = Graph.ancestors(graph, 1)
      assert MapSet.equal?(ancestors_1, MapSet.new([0]))
    end
  end
end
