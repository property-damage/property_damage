defmodule PropertyDamage.SequenceTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence

  doctest PropertyDamage.Sequence.Position

  # Mock command structs for testing
  defmodule Cmd1, do: defstruct([:id])
  defmodule Cmd2, do: defstruct([:id])
  defmodule Cmd3, do: defstruct([:id])

  describe "linear/1" do
    test "creates linear sequence with commands in prefix" do
      commands = [%Cmd1{id: 1}, %Cmd2{id: 2}]
      seq = Sequence.linear(commands)

      assert seq.prefix == commands
    end

    test "creates empty sequence" do
      seq = Sequence.linear([])
      assert seq.prefix == []
      assert Sequence.command_count(seq) == 0
    end
  end

  describe "indexed/1" do
    alias PropertyDamage.Sequence.Position

    test "pairs each command of a linear sequence with a :prefix position" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd2{id: 2}, %Cmd3{id: 3}])

      assert Sequence.indexed(seq) == [
               {%Position{section: :prefix, offset: 0}, 0, %Cmd1{id: 1}},
               {%Position{section: :prefix, offset: 1}, 1, %Cmd2{id: 2}},
               {%Position{section: :prefix, offset: 2}, 2, %Cmd3{id: 3}}
             ]
    end
  end

  describe "position_at/2" do
    alias PropertyDamage.Sequence.Position

    test "resolves executor indices to prefix positions" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd2{id: 2}])

      assert Sequence.position_at(seq, 0) == %Position{section: :prefix, offset: 0}
      assert Sequence.position_at(seq, 1) == %Position{section: :prefix, offset: 1}
    end

    test "is consistent with indexed/1 for every command" do
      seq = Sequence.linear([%Cmd1{id: 0}, %Cmd2{id: 1}, %Cmd3{id: 2}])

      for {position, index, _cmd} <- Sequence.indexed(seq) do
        assert Sequence.position_at(seq, index) == position
      end
    end
  end

  describe "Position.label/2" do
    alias PropertyDamage.Sequence.Position

    test "a leaf is labeled by the index of the root it is listed under, not its generated id" do
      # The root was generated at index 2 and printed at index 0 after a shrink.
      assert Position.label(Position.leaf(2, 0), 0) == "[0.0]"
      assert Position.label(Position.leaf(2, 1), 0) == "[0.1]"
    end

    test "a leaf position without its root raises an ArgumentError naming the root" do
      # The label cannot be printed without the root's reading-order index.
      assert_raise ArgumentError, ~r/root/, fn -> Position.label(Position.leaf(2, 1)) end
    end
  end

  describe "command_count/1" do
    test "counts commands in linear sequence" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd2{id: 2}, %Cmd3{id: 3}])
      assert Sequence.command_count(seq) == 3
    end

    test "returns 0 for empty sequence" do
      assert Sequence.command_count(Sequence.linear([])) == 0
    end
  end

  describe "to_list/1" do
    test "returns prefix for linear sequences" do
      commands = [%Cmd1{id: 1}, %Cmd2{id: 2}]
      seq = Sequence.linear(commands)
      assert Sequence.to_list(seq) == commands
    end
  end

  describe "map/2" do
    test "maps over linear sequence" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd1{id: 2}])
      mapped = Sequence.map(seq, fn %{id: id} -> %Cmd1{id: id * 10} end)

      assert mapped.prefix == [%Cmd1{id: 10}, %Cmd1{id: 20}]
    end
  end

  describe "filter/2" do
    test "filters linear sequence" do
      seq = Sequence.linear([%Cmd1{id: 1}, %Cmd1{id: 2}, %Cmd1{id: 3}])
      filtered = Sequence.filter(seq, fn %{id: id} -> rem(id, 2) == 1 end)

      assert filtered.prefix == [%Cmd1{id: 1}, %Cmd1{id: 3}]
    end
  end

  describe "append/2" do
    test "appends to prefix for linear sequences" do
      seq = Sequence.linear([%Cmd1{id: 1}])
      new_seq = Sequence.append(seq, %Cmd2{id: 2})

      assert new_seq.prefix == [%Cmd1{id: 1}, %Cmd2{id: 2}]
    end
  end

  describe "prepend/2" do
    test "prepends to prefix" do
      seq = Sequence.linear([%Cmd1{id: 2}])
      new_seq = Sequence.prepend(seq, %Cmd1{id: 1})

      assert new_seq.prefix == [%Cmd1{id: 1}, %Cmd1{id: 2}]
    end
  end
end
