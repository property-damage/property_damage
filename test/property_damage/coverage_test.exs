defmodule PropertyDamage.CoverageTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Coverage
  alias PropertyDamage.Sequence

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule TestCommand.Create do
    defstruct [:id]
  end

  defmodule TestCommand.Update do
    defstruct [:id, :value]
  end

  defmodule TestCommand.Delete do
    defstruct [:id]
  end

  defmodule TestProjection do
    @behaviour PropertyDamage.Projection

    @impl true
    def init, do: %{items: %{}, total: 0}

    @impl true
    def apply(state, _), do: state
  end

  defmodule TestModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [
        {3, TestCommand.Create},
        {2, TestCommand.Update},
        {1, TestCommand.Delete}
      ]
    end

    @impl true
    def state_projection, do: TestProjection

    @impl true
    def extra_projections, do: []
  end

  def mock_result(commands) do
    {:ok,
     %{
       sequence: Sequence.linear(commands),
       event_log: [],
       projections: %{TestProjection => %{items: %{}, total: 0}}
     }}
  end

  def mock_result_with_state(commands, state) do
    {:ok,
     %{
       sequence: Sequence.linear(commands),
       event_log: [],
       projections: %{TestProjection => state}
     }}
  end

  # ============================================================================
  # Basic Coverage Tests
  # ============================================================================

  describe "Coverage.new/1" do
    test "creates tracker with all commands from model" do
      tracker = Coverage.new(TestModel)

      assert tracker.model == TestModel
      assert MapSet.size(tracker.command_modules) == 3
      assert TestCommand.Create in tracker.command_modules
      assert TestCommand.Update in tracker.command_modules
      assert TestCommand.Delete in tracker.command_modules
    end

    test "initializes empty counts" do
      tracker = Coverage.new(TestModel)

      assert tracker.command_counts == %{}
      assert tracker.transition_counts == %{}
      assert tracker.total_commands == 0
      assert tracker.total_runs == 0
    end
  end

  describe "Coverage.record/2" do
    test "records command execution counts" do
      tracker = Coverage.new(TestModel)

      result =
        mock_result([
          %TestCommand.Create{id: "1"},
          %TestCommand.Update{id: "1", value: "a"},
          %TestCommand.Create{id: "2"}
        ])

      tracker = Coverage.record(tracker, result)

      assert tracker.command_counts[TestCommand.Create] == 2
      assert tracker.command_counts[TestCommand.Update] == 1
      assert tracker.command_counts[TestCommand.Delete] == nil
    end

    test "records transition counts" do
      tracker = Coverage.new(TestModel)

      result =
        mock_result([
          %TestCommand.Create{id: "1"},
          %TestCommand.Update{id: "1", value: "a"},
          %TestCommand.Delete{id: "1"}
        ])

      tracker = Coverage.record(tracker, result)

      assert tracker.transition_counts[{TestCommand.Create, TestCommand.Update}] == 1
      assert tracker.transition_counts[{TestCommand.Update, TestCommand.Delete}] == 1
    end

    test "accumulates across multiple records" do
      tracker = Coverage.new(TestModel)

      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "2"}]))

      assert tracker.command_counts[TestCommand.Create] == 2
      assert tracker.total_runs == 2
    end
  end

  # ============================================================================
  # Coverage Metrics Tests
  # ============================================================================

  describe "Coverage.command_coverage/1" do
    test "returns 0 when no commands executed" do
      tracker = Coverage.new(TestModel)
      assert Coverage.command_coverage(tracker) == 0.0
    end

    test "returns percentage of commands tested" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"}
          ])
        )

      # 2 out of 3 commands = 66.67%
      coverage = Coverage.command_coverage(tracker)
      assert_in_delta coverage, 66.67, 0.1
    end
  end

  describe "Coverage.transition_coverage/1" do
    test "returns percentage of transitions tested" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"}
          ])
        )

      # 1 out of 9 possible transitions (3x3)
      coverage = Coverage.transition_coverage(tracker)
      assert_in_delta coverage, 11.1, 0.1
    end
  end

  describe "Coverage.untested_commands/1" do
    test "returns list of untested commands" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([%TestCommand.Create{id: "1"}])
        )

      untested = Coverage.untested_commands(tracker)
      assert TestCommand.Update in untested
      assert TestCommand.Delete in untested
      refute TestCommand.Create in untested
    end
  end

  # ============================================================================
  # Transition Matrix Tests
  # ============================================================================

  describe "Coverage.transition_matrix/1" do
    test "returns matrix with all commands" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"}
          ])
        )

      matrix = Coverage.transition_matrix(tracker)

      # Should have entries for all commands
      assert Map.has_key?(matrix, TestCommand.Create)
      assert Map.has_key?(matrix, TestCommand.Update)
      assert Map.has_key?(matrix, TestCommand.Delete)

      # Should have correct count
      assert matrix[TestCommand.Create][TestCommand.Update] == 1
      assert matrix[TestCommand.Create][TestCommand.Delete] == 0
    end
  end

  describe "Coverage.untested_transitions/1" do
    test "returns list of untested command pairs" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"}
          ])
        )

      untested = Coverage.untested_transitions(tracker)

      # Create -> Update was tested, should not be in list
      refute {TestCommand.Create, TestCommand.Update} in untested

      # These were not tested
      assert {TestCommand.Update, TestCommand.Create} in untested
      assert {TestCommand.Delete, TestCommand.Create} in untested
    end
  end

  describe "Coverage.top_transitions/1" do
    test "returns most frequent transitions" do
      tracker = Coverage.new(TestModel)

      # Record same transition multiple times
      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"},
            %TestCommand.Create{id: "2"},
            %TestCommand.Update{id: "2", value: "b"}
          ])
        )

      top = Coverage.top_transitions(tracker, 3)

      # Create -> Update should be most frequent
      [{{from, to}, count} | _] = top
      assert from == TestCommand.Create
      assert to == TestCommand.Update
      assert count == 2
    end
  end

  # ============================================================================
  # Format Tests
  # ============================================================================

  describe "Coverage.format/2" do
    test "summary format includes basic stats" do
      tracker = Coverage.new(TestModel)
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))

      output = Coverage.format(tracker, :summary)

      assert output =~ "COVERAGE REPORT"
      assert output =~ "Total runs: 1"
      assert output =~ "Command coverage:"
    end

    test "matrix format shows transition matrix" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"}
          ])
        )

      output = Coverage.format(tracker, :matrix)

      assert output =~ "Transition Matrix"
      assert output =~ "Create"
      assert output =~ "Update"
    end

    test "full format includes everything" do
      tracker = Coverage.new(TestModel)
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))

      output = Coverage.format(tracker, :full)

      assert output =~ "COVERAGE REPORT"
      assert output =~ "Transition Matrix"
      assert output =~ "Untested Transitions"
    end
  end

  # ============================================================================
  # State Class Tests
  # ============================================================================

  describe "Coverage with state_classifier" do
    test "tracks state class counts" do
      classifier = fn state ->
        cond do
          state[:total] == 0 -> :empty
          state[:total] > 0 -> :has_items
          true -> :unknown
        end
      end

      tracker = Coverage.new(TestModel, state_classifier: classifier)

      # Record with state that has total: 0
      result = mock_result_with_state([%TestCommand.Create{id: "1"}], %{items: %{}, total: 0})

      tracker = Coverage.record(tracker, result)

      counts = Coverage.state_class_counts(tracker)
      assert counts[:empty] == 1
    end

    test "tracks state class transitions" do
      classifier = fn state ->
        cond do
          state[:total] == 0 -> :empty
          state[:total] > 0 -> :has_items
          true -> :unknown
        end
      end

      tracker = Coverage.new(TestModel, state_classifier: classifier)

      # First record: empty state
      result1 = mock_result_with_state([%TestCommand.Create{id: "1"}], %{items: %{}, total: 0})

      tracker = Coverage.record(tracker, result1)

      # Second record: has_items state
      result2 =
        mock_result_with_state([%TestCommand.Update{id: "1", value: "x"}], %{
          items: %{"1" => "x"},
          total: 1
        })

      tracker = Coverage.record(tracker, result2)

      transitions = Coverage.state_class_transitions(tracker)
      # Should have transition from empty -> has_items
      assert transitions[{:empty, :has_items}] == 1
    end

    test "format includes state class matrix when classifier set" do
      classifier = fn _state -> :some_class end

      tracker = Coverage.new(TestModel, state_classifier: classifier)
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))

      output = Coverage.format(tracker, :full)
      assert output =~ "State Class Transition Matrix"
    end

    test "state_classes format shows state class matrix" do
      classifier = fn _state -> :test_class end

      tracker = Coverage.new(TestModel, state_classifier: classifier)
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))

      output = Coverage.format(tracker, :state_classes)
      assert output =~ "State Class Transition Matrix"
      assert output =~ "test_class"
    end
  end

  # ============================================================================
  # Merge Tests
  # ============================================================================

  describe "Coverage.merge/2" do
    test "merges command counts" do
      tracker1 = Coverage.new(TestModel)
      tracker1 = Coverage.record(tracker1, mock_result([%TestCommand.Create{id: "1"}]))

      tracker2 = Coverage.new(TestModel)
      tracker2 = Coverage.record(tracker2, mock_result([%TestCommand.Create{id: "2"}]))

      merged = Coverage.merge(tracker1, tracker2)

      assert merged.command_counts[TestCommand.Create] == 2
      assert merged.total_runs == 2
    end

    test "merges transition counts" do
      tracker1 = Coverage.new(TestModel)

      tracker1 =
        Coverage.record(
          tracker1,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"}
          ])
        )

      tracker2 = Coverage.new(TestModel)

      tracker2 =
        Coverage.record(
          tracker2,
          mock_result([
            %TestCommand.Create{id: "2"},
            %TestCommand.Update{id: "2", value: "b"}
          ])
        )

      merged = Coverage.merge(tracker1, tracker2)

      assert merged.transition_counts[{TestCommand.Create, TestCommand.Update}] == 2
    end

    test "merges state class counts" do
      classifier = fn _state -> :test_class end

      tracker1 = Coverage.new(TestModel, state_classifier: classifier)
      tracker1 = Coverage.record(tracker1, mock_result([%TestCommand.Create{id: "1"}]))

      tracker2 = Coverage.new(TestModel, state_classifier: classifier)
      tracker2 = Coverage.record(tracker2, mock_result([%TestCommand.Create{id: "2"}]))

      merged = Coverage.merge(tracker1, tracker2)

      assert merged.state_class_counts[:test_class] == 2
    end
  end

  # ============================================================================
  # Threshold Tests
  # ============================================================================

  describe "Coverage.meets_threshold?/2" do
    test "returns true when thresholds met" do
      tracker = Coverage.new(TestModel)

      tracker =
        Coverage.record(
          tracker,
          mock_result([
            %TestCommand.Create{id: "1"},
            %TestCommand.Update{id: "1", value: "a"},
            %TestCommand.Delete{id: "1"}
          ])
        )

      assert Coverage.meets_threshold?(tracker, command: 90)
    end

    test "returns false when thresholds not met" do
      tracker = Coverage.new(TestModel)
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))

      refute Coverage.meets_threshold?(tracker, command: 90)
    end
  end

  # ============================================================================
  # JSON Export Tests
  # ============================================================================

  describe "Coverage.to_json/1" do
    test "exports valid JSON" do
      tracker = Coverage.new(TestModel)
      tracker = Coverage.record(tracker, mock_result([%TestCommand.Create{id: "1"}]))

      json = Coverage.to_json(tracker)
      decoded = Jason.decode!(json)

      assert is_map(decoded)
      assert Map.has_key?(decoded, "command_coverage")
      assert Map.has_key?(decoded, "transition_coverage")
    end
  end
end
