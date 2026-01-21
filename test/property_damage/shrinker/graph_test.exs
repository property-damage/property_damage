defmodule PropertyDamage.Shrinker.GraphTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Shrinker.Graph
  alias PropertyDamage.Ref

  # Test command that creates a ref
  defmodule CreateCommand do
    @behaviour PropertyDamage.Command

    defstruct [:ref, :name, :depends_on]

    @impl true
    def creates_ref, do: :ref

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # Test command that consumes a ref
  defmodule ConsumeCommand do
    @behaviour PropertyDamage.Command

    defstruct [:target_ref, :extra_ref]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # Test command with no refs
  defmodule IndependentCommand do
    @behaviour PropertyDamage.Command

    defstruct [:data]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  describe "build/1" do
    test "creates nodes for each command" do
      commands = [
        %IndependentCommand{data: 1},
        %IndependentCommand{data: 2},
        %IndependentCommand{data: 3}
      ]

      graph = Graph.build(commands)

      assert MapSet.size(graph.nodes) == 3
      assert MapSet.member?(graph.nodes, 0)
      assert MapSet.member?(graph.nodes, 1)
      assert MapSet.member?(graph.nodes, 2)
    end

    test "tracks ref producers" do
      ref1 = Ref.symbolic(label: "item1")
      ref2 = Ref.symbolic(label: "item2")

      commands = [
        %CreateCommand{ref: ref1, name: "first"},
        %CreateCommand{ref: ref2, name: "second"}
      ]

      graph = Graph.build(commands)

      # Producers are keyed by {:ref, ref_id} tuples
      assert Map.get(graph.producers, {:ref, ref1.ref}) == 0
      assert Map.get(graph.producers, {:ref, ref2.ref}) == 1
    end

    test "creates edges for consumers" do
      ref = Ref.symbolic(label: "item")

      commands = [
        %CreateCommand{ref: ref, name: "producer"},
        %ConsumeCommand{target_ref: ref}
      ]

      graph = Graph.build(commands)

      # Node 0 (producer) should have edge to node 1 (consumer)
      edges_from_0 = Map.get(graph.edges, 0, MapSet.new())
      assert MapSet.member?(edges_from_0, 1)
    end

    test "tracks consumed refs per node" do
      ref = Ref.symbolic(label: "item")

      commands = [
        %CreateCommand{ref: ref, name: "producer"},
        %ConsumeCommand{target_ref: ref}
      ]

      graph = Graph.build(commands)

      # Node 1 consumes the ref (consumers stores {:ref, ref_id} tuples)
      assert {:ref, ref.ref} in Map.get(graph.consumers, 1, [])
    end

    test "handles complex dependency graph" do
      # Create: 0 → 1 → 2, 0 → 3
      ref_a = Ref.symbolic(label: "a")
      ref_b = Ref.symbolic(label: "b")

      commands = [
        # index 0
        %CreateCommand{ref: ref_a, name: "a"},
        # index 1, consumes ref_a
        %CreateCommand{ref: ref_b, name: "b", depends_on: ref_a},
        # index 2
        %ConsumeCommand{target_ref: ref_b},
        # index 3
        %ConsumeCommand{target_ref: ref_a}
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
        %IndependentCommand{data: 1},
        %IndependentCommand{data: 2}
      ]

      graph = Graph.build(commands)
      ancestors = Graph.ancestors(graph, 0)

      assert MapSet.size(ancestors) == 0
    end

    test "returns direct dependencies" do
      ref = Ref.symbolic(label: "item")

      commands = [
        %CreateCommand{ref: ref, name: "producer"},
        %ConsumeCommand{target_ref: ref}
      ]

      graph = Graph.build(commands)
      ancestors = Graph.ancestors(graph, 1)

      assert MapSet.member?(ancestors, 0)
    end

    test "returns transitive dependencies" do
      ref_a = Ref.symbolic(label: "a")
      ref_b = Ref.symbolic(label: "b")

      # 0 creates ref_a
      # 1 consumes ref_a, creates ref_b
      # 2 consumes ref_b
      commands = [
        %CreateCommand{ref: ref_a, name: "a"},
        %CreateCommand{ref: ref_b, name: "b", depends_on: ref_a},
        %ConsumeCommand{target_ref: ref_b}
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
      ref = Ref.symbolic(label: "item")

      commands = [
        # depth 0
        %CreateCommand{ref: ref, name: "root"},
        # depth 1
        %ConsumeCommand{target_ref: ref},
        # depth 0 (no deps)
        %IndependentCommand{data: "also_root"}
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
      ref_a = Ref.symbolic(label: "a")
      ref_b = Ref.symbolic(label: "b")
      ref_c = Ref.symbolic(label: "c")

      commands = [
        %CreateCommand{ref: ref_a, name: "a"},
        %CreateCommand{ref: ref_b, name: "b", depends_on: ref_a},
        %CreateCommand{ref: ref_c, name: "c", depends_on: ref_b},
        %ConsumeCommand{target_ref: ref_c}
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
      ref = Ref.symbolic(label: "item")

      commands = [
        # index 0
        %CreateCommand{ref: ref, name: "a"},
        # index 1
        %ConsumeCommand{target_ref: ref}
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
        %IndependentCommand{data: 1},
        %IndependentCommand{data: 2},
        %IndependentCommand{data: 3}
      ]

      graph = Graph.build(commands)
      sorted = Graph.topo_sort_by_distance(graph)

      # All at same depth, sorted by index
      assert sorted == [0, 1, 2]
    end
  end

  describe "expand_super_node/2" do
    test "includes node and its ancestors" do
      ref = Ref.symbolic(label: "item")

      commands = [
        %CreateCommand{ref: ref, name: "producer"},
        %ConsumeCommand{target_ref: ref}
      ]

      graph = Graph.build(commands)

      # Want to keep node 1, must include node 0
      expanded = Graph.expand_super_node(graph, [1])

      assert 0 in expanded
      assert 1 in expanded
    end

    test "handles multiple nodes" do
      ref_a = Ref.symbolic(label: "a")
      ref_b = Ref.symbolic(label: "b")

      commands = [
        # 0
        %CreateCommand{ref: ref_a, name: "a"},
        # 1
        %CreateCommand{ref: ref_b, name: "b"},
        # 2
        %ConsumeCommand{target_ref: ref_a},
        # 3
        %ConsumeCommand{target_ref: ref_b}
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
      ref = Ref.symbolic(label: "item")

      commands = [
        %CreateCommand{ref: ref, name: "producer"},
        %ConsumeCommand{target_ref: ref}
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
      ref_root = Ref.symbolic(label: "root")
      ref_left = Ref.symbolic(label: "left")
      ref_right = Ref.symbolic(label: "right")

      commands = [
        # 0
        %CreateCommand{ref: ref_root, name: "root"},
        # 1
        %CreateCommand{ref: ref_left, name: "left", depends_on: ref_root},
        # 2
        %CreateCommand{ref: ref_right, name: "right", depends_on: ref_root},
        # 3
        %ConsumeCommand{target_ref: ref_left, extra_ref: ref_right}
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
