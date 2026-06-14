defmodule PropertyDamage.MutationTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Mutation
  alias PropertyDamage.Mutation.{Analysis, Formatter, Operator, Report}
  alias PropertyDamage.Mutation.Operators.{Boundary, Event, Omission, Status, Value}

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule TestEvent do
    defstruct [:id, :amount, :currency, :status, :description]
  end

  defmodule AnotherEvent do
    defstruct [:ref_id, :value]
  end

  defp sample_events do
    [
      %TestEvent{
        id: "evt_123",
        amount: 100,
        currency: "USD",
        status: :success,
        description: "Test"
      },
      %AnotherEvent{ref_id: "ref_456", value: 50}
    ]
  end

  # ============================================================================
  # Operator Behaviour Tests
  # ============================================================================

  describe "Operator" do
    test "built_in_operators returns all operators" do
      operators = Operator.built_in_operators()

      assert length(operators) == 5
      assert Value in operators
      assert Omission in operators
      assert Status in operators
      assert Event in operators
      assert Boundary in operators
    end

    test "operators_by_name returns correct modules" do
      modules = Operator.operators_by_name([:value, :omission])

      assert modules == [Value, Omission]
    end

    test "operators_by_name raises for unknown operator" do
      assert_raise ArgumentError, fn ->
        Operator.operators_by_name([:unknown])
      end
    end

    test "new_mutation creates mutation struct" do
      mutation =
        Operator.new_mutation(:value,
          type: :increment,
          target: :amount,
          original: 100,
          mutated: 101
        )

      assert mutation.type == :increment
      assert mutation.operator == :value
      assert mutation.target == :amount
      assert mutation.original == 100
      assert mutation.mutated == 101
    end
  end

  # ============================================================================
  # Value Mutation Tests
  # ============================================================================

  describe "Value operator" do
    test "name returns :value" do
      assert Value.name() == :value
    end

    test "generates mutations for numeric fields" do
      events = [%TestEvent{amount: 100, currency: "USD", status: :success}]
      mutations = Value.generate_mutations(events)

      # Should have mutations for the numeric field
      amount_mutations = Enum.filter(mutations, &(&1.target == :amount))
      assert amount_mutations != []

      # Should include various mutation types
      types = Enum.map(amount_mutations, & &1.type)
      assert :zero in types
      assert :negate in types
      assert :increment in types
      assert :decrement in types
    end

    test "generates mutations for string fields" do
      events = [%TestEvent{description: "Hello"}]
      mutations = Value.generate_mutations(events)

      desc_mutations = Enum.filter(mutations, &(&1.target == :description))
      assert desc_mutations != []

      types = Enum.map(desc_mutations, & &1.type)
      assert :empty in types
    end

    test "applies zero mutation" do
      events = [%TestEvent{amount: 100}]
      mutation = %{type: :zero, target: :amount, event_index: 0, mutated: 0}

      [mutated] = Value.apply_mutation(events, mutation)
      assert mutated.amount == 0
    end

    test "applies negate mutation" do
      events = [%TestEvent{amount: 100}]
      mutation = %{type: :negate, target: :amount, event_index: 0, mutated: -100}

      [mutated] = Value.apply_mutation(events, mutation)
      assert mutated.amount == -100
    end

    test "describe_mutation returns readable string" do
      mutation = %{type: :increment, target: :amount, original: 100, mutated: 101}
      desc = Value.describe_mutation(mutation)

      assert desc =~ "amount"
      assert desc =~ "100"
      assert desc =~ "101"
    end
  end

  # ============================================================================
  # Omission Mutation Tests
  # ============================================================================

  describe "Omission operator" do
    test "name returns :omission" do
      assert Omission.name() == :omission
    end

    test "generates field removal mutations" do
      events = [%TestEvent{id: "123", amount: 100}]
      mutations = Omission.generate_mutations(events)

      field_removals = Enum.filter(mutations, &(&1.type == :remove_field))
      assert field_removals != []

      targets = Enum.map(field_removals, & &1.target)
      assert :id in targets
      assert :amount in targets
    end

    test "generates event removal mutations for multiple events" do
      events = sample_events()
      mutations = Omission.generate_mutations(events)

      event_removals = Enum.filter(mutations, &(&1.type == :remove_event))
      assert length(event_removals) == 2
    end

    test "does not generate event removal for single event" do
      events = [%TestEvent{id: "123"}]
      mutations = Omission.generate_mutations(events)

      event_removals = Enum.filter(mutations, &(&1.type == :remove_event))
      assert event_removals == []
    end

    test "applies field removal mutation" do
      events = [%TestEvent{id: "123", amount: 100}]
      mutation = %{type: :remove_field, target: :amount, event_index: 0}

      [mutated] = Omission.apply_mutation(events, mutation)
      assert mutated.amount == nil
      assert mutated.id == "123"
    end

    test "applies event removal mutation" do
      events = sample_events()
      mutation = %{type: :remove_event, event_index: 0}

      mutated = Omission.apply_mutation(events, mutation)
      assert length(mutated) == 1
      assert match?(%AnotherEvent{}, hd(mutated))
    end
  end

  # ============================================================================
  # Status Mutation Tests
  # ============================================================================

  describe "Status operator" do
    test "name returns :status" do
      assert Status.name() == :status
    end

    test "generates status mutations" do
      events = sample_events()
      mutations = Status.generate_mutations(events)

      types = Enum.map(mutations, & &1.type)
      assert :success_to_error in types
      assert :empty_events in types
    end

    test "applies empty_events mutation" do
      events = sample_events()
      mutation = %{type: :empty_events}

      result = Status.apply_mutation(events, mutation)
      assert result == []
    end

    test "applies success_to_error mutation" do
      events = sample_events()
      mutation = %{type: :success_to_error, mutated: {:error, :internal_error}}

      result = Status.apply_mutation(events, mutation)
      assert result == {:error, :internal_error}
    end
  end

  # ============================================================================
  # Event Mutation Tests
  # ============================================================================

  describe "Event operator" do
    test "name returns :event" do
      assert Event.name() == :event
    end

    test "generates ref mutations for id fields" do
      events = [%TestEvent{id: "evt_123"}, %AnotherEvent{ref_id: "ref_456"}]
      mutations = Event.generate_mutations(events)

      ref_mutations = Enum.filter(mutations, &(&1.type == :wrong_ref))
      assert ref_mutations != []

      targets = Enum.map(ref_mutations, & &1.target)
      assert :id in targets or :ref_id in targets
    end

    test "generates duplicate event mutations" do
      events = sample_events()
      mutations = Event.generate_mutations(events)

      duplicates = Enum.filter(mutations, &(&1.type == :duplicate_event))
      assert length(duplicates) == 2
    end

    test "generates reorder mutations for multiple events" do
      events = sample_events()
      mutations = Event.generate_mutations(events)

      reorders = Enum.filter(mutations, &(&1.type == :reorder_events))
      assert length(reorders) == 1
    end

    test "applies wrong_ref mutation" do
      events = [%TestEvent{id: "evt_123"}]
      mutation = %{type: :wrong_ref, target: :id, event_index: 0, mutated: "evt_123_wrong"}

      [mutated] = Event.apply_mutation(events, mutation)
      assert mutated.id == "evt_123_wrong"
    end

    test "applies duplicate_event mutation" do
      events = [%TestEvent{id: "evt_123"}]
      mutation = %{type: :duplicate_event, event_index: 0}

      mutated = Event.apply_mutation(events, mutation)
      assert length(mutated) == 2
    end

    test "applies reorder_events mutation" do
      events = sample_events()
      mutation = %{type: :reorder_events, event_index: 0, swap_index: 1}

      mutated = Event.apply_mutation(events, mutation)
      assert match?(%AnotherEvent{}, hd(mutated))
      assert match?(%TestEvent{}, List.last(mutated))
    end
  end

  # ============================================================================
  # Boundary Mutation Tests
  # ============================================================================

  describe "Boundary operator" do
    test "name returns :boundary" do
      assert Boundary.name() == :boundary
    end

    test "generates boundary mutations for numeric fields" do
      events = [%TestEvent{amount: 100}]
      mutations = Boundary.generate_mutations(events)

      amount_mutations = Enum.filter(mutations, &(&1.target == :amount))
      types = Enum.map(amount_mutations, & &1.type)

      assert :zero in types
      assert :negative in types
      assert :max_int in types
      assert :null in types
    end

    test "generates boundary mutations for string fields" do
      events = [%TestEvent{description: "Hello"}]
      mutations = Boundary.generate_mutations(events)

      desc_mutations = Enum.filter(mutations, &(&1.target == :description))
      types = Enum.map(desc_mutations, & &1.type)

      assert :empty_string in types
      assert :whitespace in types
      assert :null in types
    end

    test "applies boundary mutation" do
      events = [%TestEvent{amount: 100}]
      mutation = %{type: :zero, target: :amount, event_index: 0, mutated: 0}

      [mutated] = Boundary.apply_mutation(events, mutation)
      assert mutated.amount == 0
    end
  end

  # ============================================================================
  # Report Tests
  # ============================================================================

  describe "Report" do
    test "new creates empty report" do
      report = Report.new()

      assert report.mutation_score == 0.0
      assert report.killed == 0
      assert report.survived == 0
      assert report.total == 0
    end

    test "record_result increments counters" do
      report = Report.new()

      result = %{
        command: TestEvent,
        operator: :value,
        result: :killed,
        mutation: %{},
        duration_ms: 100
      }

      report = Report.record_result(report, result)

      assert report.killed == 1
      assert report.total == 1
      assert report.mutation_score == 1.0
    end

    test "record_result tracks survived mutations" do
      report = Report.new()

      result = %{
        command: TestEvent,
        operator: :value,
        result: :survived,
        mutation: %{type: :zero, target: :amount},
        duration_ms: 100
      }

      report = Report.record_result(report, result)

      assert report.survived == 1
      assert length(report.survived_mutations) == 1
    end

    test "passes? returns true when score meets target" do
      report = %Report{mutation_score: 0.85, target_score: 0.80}
      assert Report.passes?(report)
    end

    test "passes? returns false when score below target" do
      report = %Report{mutation_score: 0.75, target_score: 0.80}
      refute Report.passes?(report)
    end

    test "weakest_commands sorts by score ascending" do
      report = %Report{
        by_command: %{
          TestEvent => %{killed: 8, survived: 2, total: 10, score: 0.8},
          AnotherEvent => %{killed: 5, survived: 5, total: 10, score: 0.5}
        }
      }

      [{cmd, _stats} | _] = Report.weakest_commands(report)
      assert cmd == AnotherEvent
    end
  end

  # ============================================================================
  # Formatter Tests
  # ============================================================================

  describe "Formatter" do
    setup do
      report = %Report{
        mutation_score: 0.85,
        killed: 17,
        survived: 3,
        timeout: 0,
        total: 20,
        by_command: %{
          TestEvent => %{killed: 10, survived: 2, total: 12, score: 0.833},
          AnotherEvent => %{killed: 7, survived: 1, total: 8, score: 0.875}
        },
        by_operator: %{
          value: %{killed: 8, survived: 1, total: 9, score: 0.889},
          omission: %{killed: 5, survived: 2, total: 7, score: 0.714}
        },
        survived_mutations: [
          %{
            command: TestEvent,
            operator: :value,
            mutation: %{target: :amount, original: 100, mutated: 0}
          }
        ],
        killed_mutations: [],
        duration_ms: 5000,
        target_score: 0.80
      }

      {:ok, report: report}
    end

    test "formats terminal output", %{report: report} do
      output = Formatter.format(report, :terminal)

      assert output =~ "MUTATION TESTING REPORT"
      assert output =~ "85"
      assert output =~ "17/20"
      assert output =~ "PASS"
      assert output =~ "TestEvent"
      assert output =~ ":value"
    end

    test "formats markdown output", %{report: report} do
      output = Formatter.format(report, :markdown)

      assert output =~ "# Mutation Testing Report"
      assert output =~ "| Metric | Value |"
      assert output =~ "85"
      assert output =~ "PASS"
    end

    test "formats json output", %{report: report} do
      output = Formatter.format(report, :json)
      decoded = Jason.decode!(output)

      assert decoded["mutation_score"] == 0.85
      assert decoded["killed"] == 17
      assert decoded["survived"] == 3
      assert decoded["passes_target"] == true
    end
  end

  # ============================================================================
  # Analysis Tests
  # ============================================================================

  describe "Analysis" do
    setup do
      report = %Report{
        mutation_score: 0.65,
        killed: 13,
        survived: 7,
        total: 20,
        by_command: %{
          TestEvent => %{killed: 5, survived: 5, total: 10, score: 0.5},
          AnotherEvent => %{killed: 8, survived: 2, total: 10, score: 0.8}
        },
        by_operator: %{
          value: %{killed: 6, survived: 4, total: 10, score: 0.6},
          omission: %{killed: 4, survived: 3, total: 7, score: 0.571},
          status: %{killed: 3, survived: 0, total: 3, score: 1.0}
        },
        survived_mutations: [
          %{
            command: TestEvent,
            operator: :value,
            mutation: %{target: :amount, original: 100, mutated: 0}
          },
          %{command: TestEvent, operator: :omission, mutation: %{target: :description}},
          %{command: TestEvent, operator: :boundary, mutation: %{target: :amount}}
        ],
        killed_mutations: [],
        target_score: 0.80
      }

      {:ok, report: report}
    end

    test "identifies weak commands", %{report: report} do
      analysis = Analysis.analyze(report)

      assert analysis.weak_commands != []
      {cmd, score} = hd(analysis.weak_commands)
      assert cmd == TestEvent
      assert score == 0.5
    end

    test "identifies weak operators", %{report: report} do
      analysis = Analysis.analyze(report)

      weak_op_names = Enum.map(analysis.weak_operators, fn {op, _} -> op end)
      assert :value in weak_op_names
      assert :omission in weak_op_names
      refute :status in weak_op_names
    end

    test "identifies unchecked fields", %{report: report} do
      analysis = Analysis.analyze(report)

      assert :amount in analysis.unchecked_fields or :description in analysis.unchecked_fields
    end

    test "generates suggestions", %{report: report} do
      analysis = Analysis.analyze(report)

      assert analysis.suggestions != []
    end

    test "generates summary", %{report: report} do
      analysis = Analysis.analyze(report)

      assert is_binary(analysis.summary)
      assert String.length(analysis.summary) > 0
    end

    test "formats analysis for terminal", %{report: report} do
      analysis = Analysis.analyze(report)
      output = Analysis.format(analysis, :terminal)

      assert output =~ "MUTATION ANALYSIS"
      assert output =~ "Weak"
    end

    test "formats analysis for markdown", %{report: report} do
      analysis = Analysis.analyze(report)
      output = Analysis.format(analysis, :markdown)

      assert output =~ "# Mutation Testing Analysis"
      assert output =~ "## Summary"
    end
  end

  # ============================================================================
  # Main API Tests
  # ============================================================================

  describe "Mutation API" do
    test "available_operators returns all operator names" do
      operators = Mutation.available_operators()

      assert :value in operators
      assert :omission in operators
      assert :status in operators
      assert :event in operators
      assert :boundary in operators
    end
  end
end
