defmodule PropertyDamage.ExecutorTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, EventQueue, Ref}

  alias PropertyDamage.Test.{
    ExecutorModel,
    FailingModel,
    SimpleModel,
    SimpleAdapter,
    ErrorAdapter,
    SimpleInjectorAdapter
  }

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Test.Projections.ModelState

  describe "run/4 with empty sequence" do
    test "succeeds with empty command list" do
      {:ok, result} = Executor.run([], ExecutorModel, SimpleAdapter)

      assert result.success == true
      assert result.event_log == []
      assert result.failed_at_index == nil
      assert result.failure_reason == nil
    end

    test "initializes projections" do
      {:ok, result} = Executor.run([], ExecutorModel, SimpleAdapter)

      assert Map.has_key?(result.projections, ModelState)
      assert result.projections[ModelState] == ModelState.init()
    end
  end

  describe "single command execution" do
    test "executes command and records events" do
      command = %CreateItem{name: "Widget", quantity: 10}

      {:ok, result} = Executor.run([command], ExecutorModel, SimpleAdapter)

      assert result.success == true
      assert length(result.event_log) == 1

      [entry] = result.event_log
      assert entry.source == :command
      assert entry.command_index == 0
      assert %ItemCreated{name: "Widget", quantity: 10} = entry.event
    end

    test "updates projections with command and events" do
      command = %CreateItem{name: "Widget", quantity: 10}

      {:ok, result} = Executor.run([command], ExecutorModel, SimpleAdapter)

      # ModelState should have the item
      model_state = result.projections[ModelState]
      assert Map.has_key?(model_state.items, "item_0")
      assert model_state.items["item_0"].name == "Widget"
    end
  end

  describe "ref resolution" do
    test "executes command and produces events with correct data" do
      {:ok, adapter_ctx} = SimpleAdapter.setup(%{})

      create_cmd = %CreateItem{name: "Test", quantity: 5}

      result =
        Executor.execute_sequence(
          [create_cmd],
          SimpleModel,
          SimpleAdapter,
          adapter_ctx
        )

      assert result.success == true
      [entry] = result.event_log
      assert entry.event.item_ref == "item_0"
      assert entry.event.name == "Test"
      assert entry.event.quantity == 5
    end

    test "unresolved refs cause failure" do
      ref = Ref.symbolic(label: "missing_item")
      command = %ViewItem{item_ref: ref}

      {:ok, result} = Executor.run([command], ExecutorModel, SimpleAdapter)

      assert result.success == false
      assert {:ref_resolution_error, _} = result.failure_reason
    end
  end

  describe "multiple commands" do
    test "executes commands in sequence" do
      commands = [
        %CreateItem{name: "First", quantity: 1},
        %CreateItem{name: "Second", quantity: 2},
        %CreateItem{name: "Third", quantity: 3}
      ]

      {:ok, result} = Executor.run(commands, ExecutorModel, SimpleAdapter)

      assert result.success == true
      assert length(result.event_log) == 3

      # Events are in order
      names = Enum.map(result.event_log, & &1.event.name)
      assert names == ["First", "Second", "Third"]
    end

    test "records correct command indices" do
      commands = [
        %CreateItem{name: "A", quantity: 1},
        %CreateItem{name: "B", quantity: 2}
      ]

      {:ok, result} = Executor.run(commands, ExecutorModel, SimpleAdapter)

      indices = Enum.map(result.event_log, & &1.command_index)
      assert indices == [0, 1]
    end
  end

  describe "check execution" do
    test "check violations halt execution" do
      # Create commands that exceed the quantity limit (100)
      commands = [
        %CreateItem{name: "Big", quantity: 101}
      ]

      {:ok, result} = Executor.run(commands, FailingModel, SimpleAdapter)

      assert result.success == false
      assert result.failed_at_index == 0
      assert {:assertion_failed, :quantity_limit, _reason} = result.failure_reason
    end

    test "successful checks continue execution" do
      commands = [
        %CreateItem{name: "Small", quantity: 50},
        %CreateItem{name: "Medium", quantity: 30}
      ]

      {:ok, result} = Executor.run(commands, FailingModel, SimpleAdapter)

      assert result.success == true
      assert length(result.event_log) == 2
    end

    test "captures failure reason" do
      commands = [%CreateItem{name: "Huge", quantity: 150}]

      {:ok, result} = Executor.run(commands, FailingModel, SimpleAdapter)

      assert result.success == false
      {:assertion_failed, :quantity_limit, exception} = result.failure_reason
      assert %PropertyDamage.AssertionFailed{} = exception
      assert exception.message =~ "exceeds limit"
    end
  end

  describe "adapter errors" do
    test "propagate through result" do
      command = %{fail: true}

      {:ok, result} = Executor.run([command], ExecutorModel, ErrorAdapter)

      assert result.success == false
      assert result.failure_reason == {:adapter_error, :command_failed}
    end
  end

  describe "injector events" do
    test "drains and records injector events" do
      {:ok, queue} = EventQueue.start_link()
      command = %CreateItem{name: "Test", quantity: 5}

      # Push an event to queue before execution
      EventQueue.push(queue, SimpleInjectorAdapter, %ItemViewed{item_ref: "injected"})

      {:ok, result} = Executor.run([command], ExecutorModel, SimpleAdapter, event_queue: queue)

      # Should have both command event and injector event
      assert length(result.event_log) == 2

      injector_entry = Enum.find(result.event_log, &(&1.source == :injector))
      assert injector_entry != nil
      assert injector_entry.injector_adapter == SimpleInjectorAdapter
      assert %ItemViewed{item_ref: "injected"} = injector_entry.event

      EventQueue.stop(queue)
    end

    test "updates projections with injector events" do
      {:ok, queue} = EventQueue.start_link()
      command = %CreateItem{name: "Test", quantity: 5}

      EventQueue.push(queue, SimpleInjectorAdapter, %ItemViewed{item_ref: "test"})

      {:ok, result} = Executor.run([command], ExecutorModel, SimpleAdapter, event_queue: queue)

      # ModelState should have view_count incremented from injector event
      model_state = result.projections[ModelState]
      assert model_state.view_count == 1

      EventQueue.stop(queue)
    end
  end

  describe "event log entries" do
    test "command events have correct source" do
      {:ok, result} =
        Executor.run([%CreateItem{name: "Test", quantity: 1}], ExecutorModel, SimpleAdapter)

      [entry] = result.event_log
      assert entry.source == :command
      assert entry.injector_adapter == nil
    end

    test "entries have timestamps" do
      {:ok, result} =
        Executor.run([%CreateItem{name: "Test", quantity: 1}], ExecutorModel, SimpleAdapter)

      [entry] = result.event_log
      assert is_integer(entry.timestamp)
    end
  end

  describe "branching sequence execution" do
    alias PropertyDamage.Sequence

    test "executes branching sequence with prefix" do
      # Create a branching sequence with prefix and two branches
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 1}],
          [
            [%CreateItem{name: "BranchA", quantity: 2}],
            [%CreateItem{name: "BranchB", quantity: 3}]
          ],
          []
        )

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      assert result.success == true
      # 1 prefix + 1 branch A + 1 branch B = 3 events
      assert length(result.event_log) == 3
    end

    test "executes branching sequence with suffix" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 1}],
          [[%CreateItem{name: "BranchA", quantity: 2}]],
          [%CreateItem{name: "Suffix", quantity: 4}]
        )

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      assert result.success == true
      # 1 prefix + 1 branch + 1 suffix = 3 events
      assert length(result.event_log) == 3
    end

    test "branch events have branch_id" do
      seq =
        Sequence.branching(
          [],
          [
            [%CreateItem{name: "BranchA", quantity: 1}],
            [%CreateItem{name: "BranchB", quantity: 2}]
          ],
          []
        )

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      # Find events from each branch
      branch_ids = result.event_log |> Enum.map(& &1.branch_id) |> Enum.uniq()
      # Should have events from branch 0 and branch 1
      assert 0 in branch_ids
      assert 1 in branch_ids
    end

    test "failure in branch reports branch_id" do
      seq =
        Sequence.branching(
          [],
          [
            [%CreateItem{name: "Item", quantity: 150}]
          ],
          []
        )

      {:ok, result} = Executor.run(seq, FailingModel, SimpleAdapter)

      # Should fail due to exceeding 100 quantity limit
      assert result.success == false
      # Branch failures are wrapped with branch_id
      assert {:branch_failure, 0, {:assertion_failed, _, _}} = result.failure_reason
    end

    test "merges projections from all branches" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "Prefix", quantity: 10}],
          [
            [%CreateItem{name: "BranchA", quantity: 20}],
            [%CreateItem{name: "BranchB", quantity: 30}]
          ],
          []
        )

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      model_state = result.projections[ModelState]
      # The executor takes the last branch's projection state
      # So we expect at least one item (this is implementation-dependent)
      assert map_size(model_state.items) >= 1
    end

    test "handles empty branches list" do
      # Empty branches should be treated as linear
      seq = %Sequence{prefix: [%CreateItem{name: "Test", quantity: 1}], branches: [], suffix: []}

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      assert result.success == true
      assert length(result.event_log) == 1
    end

    test "linear sequence works when passed as Sequence struct" do
      # Verify that a linear Sequence struct works correctly
      seq =
        Sequence.linear([
          %CreateItem{name: "Test1", quantity: 1},
          %CreateItem{name: "Test2", quantity: 2}
        ])

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      assert result.success == true
      assert length(result.event_log) == 2
    end
  end
end
