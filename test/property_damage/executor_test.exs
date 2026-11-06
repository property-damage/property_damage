defmodule PropertyDamage.ExecutorTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.{EventQueue, Executor, Failure, Placeholder}

  alias PropertyDamage.Test.{
    ErrorAdapter,
    ExecutorModel,
    FailingModel,
    SimpleAdapter,
    SimpleInjectorAdapter,
    SimpleModel
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

    test "unresolved externals cause failure" do
      # A placeholder that was never registered cannot resolve, so the command
      # fails resolution (surfaced as :ref_resolution_error).
      ph = Placeholder.new_at(ItemCreated, [:item_ref], Position.prefix(0), 0)
      command = %ViewItem{item_ref: ph}

      {:ok, result} = Executor.run([command], ExecutorModel, SimpleAdapter)

      assert result.success == false
      assert Failure.kind(result.failure_reason) == :placeholder_resolution
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

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :quantity_limit}} =
               result.failure_reason
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

      %Failure{
        type: %Failure.Check{
          kind: :check_failed,
          name: :quantity_limit,
          detail: exception
        }
      } =
        result.failure_reason

      assert %PropertyDamage.CheckFailed{} = exception
      assert exception.message =~ "exceeds limit"
    end
  end

  describe "record check mode" do
    test "recorded failures are returned in chronological order" do
      # total_quantity accumulates, so once it exceeds 100 every subsequent
      # command also fails. The recorded failures must read oldest-first.
      commands = [
        %CreateItem{name: "A", quantity: 101},
        %CreateItem{name: "B", quantity: 60},
        %CreateItem{name: "C", quantity: 70}
      ]

      {:ok, result} =
        Executor.run(commands, FailingModel, SimpleAdapter, check_mode: :record)

      assert result.success == false

      indices = Enum.map(result.check_failures, & &1.command_index)
      assert length(indices) >= 2

      assert indices == Enum.sort(indices),
             "expected chronological order, got #{inspect(indices)}"
    end
  end

  describe "execute_raw/3" do
    test "preserves event order across commands" do
      commands = [
        %CreateItem{name: "A", quantity: 1},
        %CreateItem{name: "B", quantity: 2},
        %CreateItem{name: "C", quantity: 3}
      ]

      # execute_raw/3 bypasses setup/1, so the caller supplies the context the
      # adapter needs (here SimpleAdapter's per-run counter).
      {:ok, events} =
        Executor.execute_raw(commands, SimpleAdapter, %{
          adapter_context: %{item_counter: :atomics.new(1, [])}
        })

      names = Enum.map(events, & &1.event.name)
      assert names == ["A", "B", "C"]
    end
  end

  describe "adapter errors" do
    test "propagate through result" do
      command = %{fail: true}

      {:ok, result} = Executor.run([command], ExecutorModel, ErrorAdapter)

      assert result.success == false

      assert %Failure{type: %Failure.Execution{kind: :adapter_error, detail: :command_failed}} =
               result.failure_reason
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
end
