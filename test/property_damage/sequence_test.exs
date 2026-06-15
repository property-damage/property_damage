defmodule PropertyDamage.SequenceTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence

  # Mock command structs for testing
  defmodule Cmd1, do: defstruct([:id])
  defmodule Cmd2, do: defstruct([:id])
  defmodule Cmd3, do: defstruct([:id])

  describe "linear/1" do
    test "creates linear sequence with commands in prefix" do
      commands = [%Cmd1{id: 1}, %Cmd2{id: 2}]
      seq = Sequence.linear(commands)

      assert seq.prefix == commands
      assert seq.branches == nil
      assert seq.suffix == []
    end

    test "creates empty sequence" do
      seq = Sequence.linear([])
      assert seq.prefix == []
      assert Sequence.linear?(seq)
    end
  end

  describe "branching/3" do
    test "creates branching sequence with all parts" do
      prefix = [%Cmd1{id: 1}]
      branches = [[%Cmd2{id: 2}], [%Cmd3{id: 3}]]
      suffix = [%Cmd1{id: 4}]

      seq = Sequence.branching(prefix, branches, suffix)

      assert seq.prefix == prefix
      assert seq.branches == branches
      assert seq.suffix == suffix
    end

    test "suffix defaults to empty list" do
      seq = Sequence.branching([%Cmd1{id: 1}], [[%Cmd2{id: 2}]])
      assert seq.suffix == []
    end
  end

  describe "linear?/1" do
    test "returns true for linear sequences" do
      assert Sequence.linear?(Sequence.linear([%Cmd1{id: 1}]))
    end

    test "returns true for empty branches" do
      seq = %Sequence{prefix: [%Cmd1{id: 1}], branches: [], suffix: []}
      assert Sequence.linear?(seq)
    end

    test "returns false for branching sequences" do
      seq = Sequence.branching([%Cmd1{id: 1}], [[%Cmd2{id: 2}]])
      refute Sequence.linear?(seq)
    end
  end

  describe "branching?/1" do
    test "returns true for branching sequences" do
      seq = Sequence.branching([%Cmd1{id: 1}], [[%Cmd2{id: 2}]])
      assert Sequence.branching?(seq)
    end

    test "returns false for linear sequences" do
      seq = Sequence.linear([%Cmd1{id: 1}])
      refute Sequence.branching?(seq)
    end
  end

  describe "command_count/1" do
    test "counts commands in linear sequence" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd2{id: 2}, %Cmd3{id: 3}])
      assert Sequence.command_count(seq) == 3
    end

    test "counts commands in branching sequence" do
      seq =
        Sequence.branching(
          [%Cmd1{id: 1}],
          [[%Cmd2{id: 2}, %Cmd3{id: 3}], [%Cmd1{id: 4}]],
          [%Cmd2{id: 5}]
        )

      # 1 prefix + 2 in branch 1 + 1 in branch 2 + 1 suffix = 5
      assert Sequence.command_count(seq) == 5
    end

    test "returns 0 for empty sequence" do
      assert Sequence.command_count(Sequence.linear([])) == 0
    end
  end

  describe "branch_count/1" do
    test "returns 0 for linear sequences" do
      assert Sequence.branch_count(Sequence.linear([%Cmd1{id: 1}])) == 0
    end

    test "returns number of branches" do
      seq = Sequence.branching([], [[%Cmd1{id: 1}], [%Cmd2{id: 2}], [%Cmd3{id: 3}]])
      assert Sequence.branch_count(seq) == 3
    end
  end

  describe "to_list/1" do
    test "returns prefix for linear sequences" do
      commands = [%Cmd1{id: 1}, %Cmd2{id: 2}]
      seq = Sequence.linear(commands)
      assert Sequence.to_list(seq) == commands
    end

    test "flattens branching sequences" do
      seq =
        Sequence.branching(
          [%Cmd1{id: 1}],
          [[%Cmd2{id: 2}], [%Cmd3{id: 3}]],
          [%Cmd1{id: 4}]
        )

      result = Sequence.to_list(seq)
      assert length(result) == 4
      assert hd(result) == %Cmd1{id: 1}
      assert List.last(result) == %Cmd1{id: 4}
    end
  end

  describe "map/2" do
    test "maps over linear sequence" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd1{id: 2}])
      mapped = Sequence.map(seq, fn %{id: id} -> %Cmd1{id: id * 10} end)

      assert mapped.prefix == [%Cmd1{id: 10}, %Cmd1{id: 20}]
      assert mapped.branches == nil
    end

    test "maps over branching sequence preserving structure" do
      seq =
        Sequence.branching(
          [%Cmd1{id: 1}],
          [[%Cmd1{id: 2}], [%Cmd1{id: 3}]],
          [%Cmd1{id: 4}]
        )

      mapped = Sequence.map(seq, fn %{id: id} -> %Cmd1{id: id * 10} end)

      assert mapped.prefix == [%Cmd1{id: 10}]
      assert mapped.branches == [[%Cmd1{id: 20}], [%Cmd1{id: 30}]]
      assert mapped.suffix == [%Cmd1{id: 40}]
    end
  end

  describe "filter/2" do
    test "filters linear sequence" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd1{id: 2}, %Cmd1{id: 3}])
      filtered = Sequence.filter(seq, fn %{id: id} -> rem(id, 2) == 1 end)

      assert filtered.prefix == [%Cmd1{id: 1}, %Cmd1{id: 3}]
    end

    test "filters branching sequence" do
      seq =
        Sequence.branching(
          [%Cmd1{id: 1}, %Cmd1{id: 2}],
          [[%Cmd1{id: 3}, %Cmd1{id: 4}], [%Cmd1{id: 5}]],
          [%Cmd1{id: 6}]
        )

      # Keep only odd IDs
      filtered = Sequence.filter(seq, fn %{id: id} -> rem(id, 2) == 1 end)

      assert filtered.prefix == [%Cmd1{id: 1}]
      assert filtered.branches == [[%Cmd1{id: 3}], [%Cmd1{id: 5}]]
      assert filtered.suffix == []
    end

    test "converts to linear when all branches empty" do
      seq = Sequence.branching([%Cmd1{id: 1}], [[%Cmd1{id: 2}], [%Cmd1{id: 4}]], [])

      # Filter out all even IDs (removes all branch commands)
      filtered = Sequence.filter(seq, fn %{id: id} -> rem(id, 2) == 1 end)

      assert Sequence.linear?(filtered)
      assert filtered.prefix == [%Cmd1{id: 1}]
    end

    test "converts to linear when only one branch survives" do
      seq =
        Sequence.branching(
          [%Cmd1{id: 1}],
          [[%Cmd1{id: 2}, %Cmd1{id: 3}], [%Cmd1{id: 4}]],
          [%Cmd1{id: 5}]
        )

      # Keep ids 1, 3, 5: branch 0 -> [3], branch 1 -> [] (dropped), so a
      # single branch remains. A one-branch sequence is not parallel, so it
      # must collapse to linear (prefix ++ branch ++ suffix).
      filtered = Sequence.filter(seq, fn %{id: id} -> id in [1, 3, 5] end)

      assert Sequence.linear?(filtered)
      assert filtered.prefix == [%Cmd1{id: 1}, %Cmd1{id: 3}, %Cmd1{id: 5}]
      assert filtered.branches == nil
      assert filtered.suffix == []
    end
  end

  describe "append/2" do
    test "appends to prefix for linear sequences" do
      seq = Sequence.linear([%Cmd1{id: 1}])
      new_seq = Sequence.append(seq, %Cmd2{id: 2})

      assert new_seq.prefix == [%Cmd1{id: 1}, %Cmd2{id: 2}]
    end

    test "appends to suffix for branching sequences" do
      seq = Sequence.branching([%Cmd1{id: 1}], [[%Cmd2{id: 2}]], [])
      new_seq = Sequence.append(seq, %Cmd3{id: 3})

      assert new_seq.suffix == [%Cmd3{id: 3}]
    end
  end

  describe "prepend/2" do
    test "prepends to prefix" do
      seq = Sequence.linear([%Cmd1{id: 2}])
      new_seq = Sequence.prepend(seq, %Cmd1{id: 1})

      assert new_seq.prefix == [%Cmd1{id: 1}, %Cmd1{id: 2}]
    end
  end

  describe "add_branch/2" do
    test "converts linear to branching" do
      seq = Sequence.linear([%Cmd1{id: 1}])
      new_seq = Sequence.add_branch(seq, [%Cmd2{id: 2}])

      assert Sequence.branching?(new_seq)
      assert new_seq.prefix == [%Cmd1{id: 1}]
      assert new_seq.branches == [[%Cmd2{id: 2}]]
    end

    test "adds branch to existing branching sequence" do
      seq = Sequence.branching([%Cmd1{id: 1}], [[%Cmd2{id: 2}]])
      new_seq = Sequence.add_branch(seq, [%Cmd3{id: 3}])

      assert new_seq.branches == [[%Cmd2{id: 2}], [%Cmd3{id: 3}]]
    end
  end

  describe "linearizations/1" do
    test "returns single element for linear sequences" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd2{id: 2}])
      linearizations = Sequence.linearizations(seq)

      assert length(linearizations) == 1
      assert hd(linearizations) == seq
    end

    test "generates all interleavings for two branches" do
      seq =
        Sequence.branching(
          [],
          [[%Cmd1{id: :a1}, %Cmd1{id: :a2}], [%Cmd1{id: :b1}]],
          []
        )

      linearizations = Sequence.linearizations(seq)

      # With [a1, a2] and [b1], valid orderings are:
      # [a1, a2, b1], [a1, b1, a2], [b1, a1, a2]
      assert length(linearizations) == 3

      # All should be linear
      for lin <- linearizations do
        assert Sequence.linear?(lin), "expected linear sequence: #{inspect(lin)}"
      end

      # Each should have 3 commands
      for lin <- linearizations do
        assert Sequence.command_count(lin) == 3,
               "expected 3 commands, got #{Sequence.command_count(lin)}"
      end
    end

    test "preserves order within branches" do
      seq =
        Sequence.branching(
          [],
          [[%Cmd1{id: :a1}, %Cmd1{id: :a2}], [%Cmd1{id: :b1}, %Cmd1{id: :b2}]],
          []
        )

      linearizations = Sequence.linearizations(seq)

      # Check that a1 always comes before a2, and b1 before b2
      for lin <- linearizations do
        commands = Sequence.to_list(lin)
        ids = Enum.map(commands, & &1.id)

        a1_idx = Enum.find_index(ids, &(&1 == :a1))
        a2_idx = Enum.find_index(ids, &(&1 == :a2))
        b1_idx = Enum.find_index(ids, &(&1 == :b1))
        b2_idx = Enum.find_index(ids, &(&1 == :b2))

        assert a1_idx < a2_idx, "a1 should come before a2"
        assert b1_idx < b2_idx, "b1 should come before b2"
      end
    end

    test "includes prefix and suffix in all linearizations" do
      seq =
        Sequence.branching(
          [%Cmd1{id: :prefix}],
          [[%Cmd1{id: :a}], [%Cmd1{id: :b}]],
          [%Cmd1{id: :suffix}]
        )

      linearizations = Sequence.linearizations(seq)

      for lin <- linearizations do
        commands = Sequence.to_list(lin)
        ids = Enum.map(commands, & &1.id)

        # Prefix should be first
        assert hd(ids) == :prefix
        # Suffix should be last
        assert List.last(ids) == :suffix
      end
    end
  end
end
