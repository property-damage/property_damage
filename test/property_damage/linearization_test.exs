defmodule PropertyDamage.LinearizationTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Linearization
  alias PropertyDamage.EventLog.Entry

  # Simple test projection for linearization tests
  defmodule TestProjection do
    def init, do: %{total: 0, items: []}

    def handles?(_), do: true

    def apply(state, %{type: :add, value: v}) do
      %{state | total: state.total + v, items: state.items ++ [v]}
    end

    def apply(state, _), do: state
  end

  # Test model
  defmodule TestModel do
    @behaviour PropertyDamage.Model

    def commands, do: []
    def state_projection, do: TestProjection
    def extra_projections, do: []
  end

  describe "generate_linearizations/1" do
    test "returns single list for empty branches" do
      assert Linearization.generate_linearizations([]) == [[]]
    end

    test "returns single list for single branch" do
      branch = [%{id: 1}, %{id: 2}]
      result = Linearization.generate_linearizations([branch])

      assert result == [branch]
    end

    test "generates all interleavings for two branches" do
      branch_a = [%{id: :a1}, %{id: :a2}]
      branch_b = [%{id: :b1}]

      result = Linearization.generate_linearizations([branch_a, branch_b])

      # With [a1, a2] and [b1], valid orderings are:
      # [a1, a2, b1], [a1, b1, a2], [b1, a1, a2]
      assert length(result) == 3

      # Each linearization should have 3 commands
      for linearization <- result do
        assert length(linearization) == 3,
               "expected 3 commands, got #{length(linearization)}"
      end

      # a1 should come before a2 in all orderings
      for lin <- result do
        ids = Enum.map(lin, & &1.id)
        a1_idx = Enum.find_index(ids, &(&1 == :a1))
        a2_idx = Enum.find_index(ids, &(&1 == :a2))
        assert a1_idx < a2_idx, "a1 should come before a2"
      end
    end

    test "generates correct count for equal-length branches" do
      # Two branches of length 2 each
      # (2+2)! / (2! * 2!) = 24 / 4 = 6
      branch_a = [%{id: :a1}, %{id: :a2}]
      branch_b = [%{id: :b1}, %{id: :b2}]

      result = Linearization.generate_linearizations([branch_a, branch_b])

      assert length(result) == 6
    end
  end

  describe "linearization_count/1" do
    test "returns 1 for empty branches" do
      assert Linearization.linearization_count([]) == 1
    end

    test "returns 1 for single branch" do
      assert Linearization.linearization_count([[1, 2, 3]]) == 1
    end

    test "calculates correct count for two branches" do
      # [1, 2] and [a] -> (2+1)! / (2! * 1!) = 6 / 2 = 3
      assert Linearization.linearization_count([[1, 2], [:a]]) == 3
    end

    test "calculates correct count for equal branches" do
      # [1, 2] and [a, b] -> (2+2)! / (2! * 2!) = 24 / 4 = 6
      assert Linearization.linearization_count([[1, 2], [:a, :b]]) == 6
    end

    test "calculates correct count for three branches" do
      # [1] [2] [3] -> (1+1+1)! / (1! * 1! * 1!) = 6 / 1 = 6
      assert Linearization.linearization_count([[1], [2], [3]]) == 6
    end
  end

  describe "feasibility/1" do
    test "returns :ok for small branch sets" do
      branches = [[1, 2], [3, 4]]
      assert Linearization.feasibility(branches) == :ok
    end

    test "returns warning for large branch sets" do
      # Create branches that would have > 1000 linearizations
      branches = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11]]
      result = Linearization.feasibility(branches)

      assert {:warning, count} = result
      assert count > 1000
    end
  end

  describe "check/4" do
    test "finds valid linearization for simple branches" do
      # Create simple branch commands
      cmd_a = %{id: :a, value: 10}
      cmd_b = %{id: :b, value: 20}

      branch_commands = [[cmd_a], [cmd_b]]

      # Create matching events using Entry.from_command/3
      branch_events = %{
        0 => [
          Entry.from_command(%{type: :add, value: 10}, 0, timestamp: 1)
        ],
        1 => [
          Entry.from_command(%{type: :add, value: 20}, 1, timestamp: 2)
        ]
      }

      projections = %{TestProjection => TestProjection.init()}

      result = Linearization.check(branch_commands, branch_events, projections, TestModel)

      assert {:ok, linearization} = result
      assert length(linearization) == 2
    end

    test "returns first valid linearization found" do
      cmd_a = %{id: :a}
      cmd_b = %{id: :b}

      branch_commands = [[cmd_a], [cmd_b]]

      # Both orderings produce the same final state (no events)
      branch_events = %{
        0 => [],
        1 => []
      }

      projections = %{TestProjection => TestProjection.init()}

      result = Linearization.check(branch_commands, branch_events, projections, TestModel)

      # Should find a valid linearization
      assert {:ok, _linearization} = result
    end
  end

  describe "verify/4" do
    test "verifies a valid linearization" do
      cmd_a = %{id: :a, value: 10}
      linearization = [cmd_a]

      branch_events = %{
        0 => [
          Entry.from_command(%{type: :add, value: 10}, 0, timestamp: 1)
        ]
      }

      projections = %{TestProjection => TestProjection.init()}

      result = Linearization.verify(linearization, branch_events, projections, TestModel)

      assert result == true
    end
  end
end
