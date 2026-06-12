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
    def command_sequence_projection, do: TestProjection
    def assertion_projections, do: []
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

  # ============================================================================
  # Counter model: the canonical linearizability example. The simulator
  # predicts Incremented{from: n, to: n+1}; a lost update (two increments
  # both observing from: 0) is explainable by NO sequential order.
  # ============================================================================

  defmodule Counter do
    defmodule Incr do
      defstruct [:id]
    end

    defmodule Incremented do
      defstruct [:from, :to]
    end
  end

  defmodule CounterProjection do
    def init, do: %{count: 0}

    def apply(state, %Counter.Incremented{to: to}), do: %{state | count: to}
    def apply(state, _), do: state
  end

  defmodule CounterModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl PropertyDamage.Model
    def commands, do: []

    @impl PropertyDamage.Model
    def command_sequence_projection, do: CounterProjection

    @impl PropertyDamage.Model
    def assertion_projections, do: []

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Counter.Incr{}, state) do
      [%Counter.Incremented{from: state.count, to: state.count + 1}]
    end

    def simulate(_, _), do: []
  end

  defp counter_projections do
    %{CounterProjection => CounterProjection.init()}
  end

  defp incr_entry(from, to, command_index) do
    Entry.from_command(%Counter.Incremented{from: from, to: to}, command_index, timestamp: 1)
  end

  describe "check/5" do
    test "accepts a healthy sequential history of two parallel increments" do
      branch_commands = [[%Counter.Incr{id: :a}], [%Counter.Incr{id: :b}]]

      # Branch a observed 0->1, branch b observed 1->2: order a,b explains it
      branch_events = %{
        0 => [incr_entry(0, 1, 0)],
        1 => [incr_entry(1, 2, 0)]
      }

      assert {:ok, linearization} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 counter_projections(),
                 CounterModel
               )

      assert [{0, 0, %Counter.Incr{id: :a}}, {1, 0, %Counter.Incr{id: :b}}] = linearization
    end

    test "rejects a lost update: no sequential order explains it" do
      branch_commands = [[%Counter.Incr{id: :a}], [%Counter.Incr{id: :b}]]

      # BOTH increments observed 0->1: the classic race. Whichever command
      # goes second should have seen from: 1.
      branch_events = %{
        0 => [incr_entry(0, 1, 0)],
        1 => [incr_entry(0, 1, 0)]
      }

      assert Linearization.check(
               branch_commands,
               branch_events,
               counter_projections(),
               CounterModel
             ) == :no_linearization
    end

    test "respects start_index when translating entry indices to positions" do
      branch_commands = [[%Counter.Incr{id: :a}], [%Counter.Incr{id: :b}]]

      # Branches started at executor index 3 (after a 3-command prefix)
      branch_events = %{
        0 => [incr_entry(0, 1, 3)],
        1 => [incr_entry(1, 2, 3)]
      }

      assert {:ok, _} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 counter_projections(),
                 CounterModel,
                 start_index: 3
               )
    end

    test "finds the valid order regardless of branch position" do
      branch_commands = [[%Counter.Incr{id: :a}], [%Counter.Incr{id: :b}]]

      # Branch b went FIRST: observed b: 0->1, a: 1->2
      branch_events = %{
        0 => [incr_entry(1, 2, 0)],
        1 => [incr_entry(0, 1, 0)]
      }

      assert {:ok, linearization} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 counter_projections(),
                 CounterModel
               )

      assert [{1, 0, %Counter.Incr{id: :b}}, {0, 0, %Counter.Incr{id: :a}}] = linearization
    end

    test "is indeterminate for models without a simulator" do
      branch_commands = [[%{id: :a}], [%{id: :b}]]
      branch_events = %{0 => [], 1 => []}
      projections = %{TestProjection => TestProjection.init()}

      assert Linearization.check(branch_commands, branch_events, projections, TestModel) ==
               {:indeterminate, 0}
    end

    test "is indeterminate when the candidate cap is reached without success" do
      # Two racing increments (refutable), but a cap of 1 examines only the
      # first interleaving: refuted, not exhausted, so indeterminate
      branch_commands = [[%Counter.Incr{id: :a}], [%Counter.Incr{id: :b}]]

      branch_events = %{
        0 => [incr_entry(0, 1, 0)],
        1 => [incr_entry(0, 1, 0)]
      }

      assert {:indeterminate, 1} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 counter_projections(),
                 CounterModel,
                 max_candidates: 1
               )
    end
  end

  describe "verify/4" do
    test "accepts a consistent tagged linearization" do
      linearization = [{0, 0, %Counter.Incr{id: :a}}, {1, 0, %Counter.Incr{id: :b}}]

      observed = %{
        {0, 0} => [%Counter.Incremented{from: 0, to: 1}],
        {1, 0} => [%Counter.Incremented{from: 1, to: 2}]
      }

      assert Linearization.verify(linearization, observed, counter_projections(), CounterModel)
    end

    test "refutes an inconsistent tagged linearization" do
      # Claims a runs first, but a observed from: 1 (it actually ran second)
      linearization = [{0, 0, %Counter.Incr{id: :a}}, {1, 0, %Counter.Incr{id: :b}}]

      observed = %{
        {0, 0} => [%Counter.Incremented{from: 1, to: 2}],
        {1, 0} => [%Counter.Incremented{from: 0, to: 1}]
      }

      refute Linearization.verify(linearization, observed, counter_projections(), CounterModel)
    end

    test "treats nil predicted fields as wildcards" do
      defmodule NilSimModel do
        @behaviour PropertyDamage.Model
        @behaviour PropertyDamage.Model.Simulator

        @impl PropertyDamage.Model
        def commands, do: []
        @impl PropertyDamage.Model
        def command_sequence_projection, do: CounterProjection
        @impl PropertyDamage.Model
        def assertion_projections, do: []
        @impl PropertyDamage.Model
        def simulator, do: __MODULE__

        @impl PropertyDamage.Model.Simulator
        def simulate(%Counter.Incr{}, _state) do
          # Server-decided values predicted as nil: wildcard
          [%Counter.Incremented{from: nil, to: nil}]
        end

        def simulate(_, _), do: []
      end

      linearization = [{0, 0, %Counter.Incr{id: :a}}]
      observed = %{{0, 0} => [%Counter.Incremented{from: 0, to: 1}]}

      assert Linearization.verify(
               linearization,
               observed,
               counter_projections(),
               NilSimModel
             )
    end

    test "refutes when an expected event has no observed counterpart" do
      linearization = [{0, 0, %Counter.Incr{id: :a}}]
      observed = %{{0, 0} => []}

      refute Linearization.verify(linearization, observed, counter_projections(), CounterModel)
    end
  end
end
