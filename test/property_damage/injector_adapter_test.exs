defmodule PropertyDamage.Adapter.InjectorTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Adapter.Injector
  alias PropertyDamage.EventQueue

  alias PropertyDamage.Test.{
    SimpleInjectorAdapter,
    RespondingInjectorAdapter,
    FailingInjectorAdapter,
    NoEmitsInjectorAdapter
  }

  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  describe "Adapter.Injector behaviour" do
    test "compiles with required callbacks" do
      Code.ensure_loaded!(SimpleInjectorAdapter)

      assert function_exported?(SimpleInjectorAdapter, :setup, 1)
      assert function_exported?(SimpleInjectorAdapter, :teardown, 1)
      assert function_exported?(SimpleInjectorAdapter, :to_event, 1)
    end

    test "optional respond/2 callback can be implemented" do
      Code.ensure_loaded!(RespondingInjectorAdapter)

      assert function_exported?(RespondingInjectorAdapter, :respond, 2)
    end

    test "respond/2 is optional" do
      Code.ensure_loaded!(SimpleInjectorAdapter)

      refute function_exported?(SimpleInjectorAdapter, :respond, 2)
    end
  end

  describe "@emits attribute" do
    test "is captured via __emits__/0" do
      emits = SimpleInjectorAdapter.__emits__()

      assert ItemCreated in emits
      assert ItemViewed in emits
      assert length(emits) == 2
    end

    test "defaults to empty list when not specified" do
      emits = NoEmitsInjectorAdapter.__emits__()

      assert emits == []
    end
  end

  describe "setup/1" do
    test "receives event_queue in config" do
      {:ok, queue} = EventQueue.start_link()

      {:ok, context} = SimpleInjectorAdapter.setup(%{event_queue: queue})

      assert context.event_queue == queue
      assert context.setup_called == true

      EventQueue.stop(queue)
    end

    test "can return error" do
      result = FailingInjectorAdapter.setup(%{fail_setup: true})

      assert result == {:error, :setup_failed}
    end
  end

  describe "teardown/1" do
    test "returns :ok" do
      {:ok, context} = SimpleInjectorAdapter.setup(%{})

      result = SimpleInjectorAdapter.teardown(context)

      assert result == :ok
    end
  end

  describe "to_event/1" do
    test "transforms payload to event" do
      payload = %{type: :item_created, name: "Widget", quantity: 10}

      {:ok, event} = SimpleInjectorAdapter.to_event(payload)

      assert %ItemCreated{name: "Widget", quantity: 10} = event
    end

    test "returns :skip for unknown payloads" do
      result = SimpleInjectorAdapter.to_event(%{type: :unknown})

      assert result == :skip
    end

    test "returns error for invalid payloads" do
      result = SimpleInjectorAdapter.to_event(%{type: :invalid})

      assert result == {:error, :invalid_payload}
    end

    test "handles multiple event types" do
      {:ok, created} =
        SimpleInjectorAdapter.to_event(%{
          type: :item_created,
          name: "A",
          quantity: 1
        })

      {:ok, viewed} =
        SimpleInjectorAdapter.to_event(%{
          type: :item_viewed,
          item_ref: "ref-123"
        })

      assert %ItemCreated{} = created
      assert %ItemViewed{item_ref: "ref-123"} = viewed
    end
  end

  describe "respond/2" do
    test "generates response for event" do
      {:ok, context} = RespondingInjectorAdapter.setup(%{})
      event = %ItemCreated{item_ref: nil, name: "Widget", quantity: 5}

      {:ok, response} = RespondingInjectorAdapter.respond(event, context)

      assert response.status == 200
      assert response.body == "Created: Widget"
    end

    test "can return :none for no response" do
      {:ok, context} = RespondingInjectorAdapter.setup(%{})
      event = %ItemViewed{item_ref: "ref-123"}

      result = RespondingInjectorAdapter.respond(event, context)

      assert result == :none
    end
  end

  describe "integration with EventQueue" do
    test "can push events to queue" do
      {:ok, queue} = EventQueue.start_link()
      {:ok, context} = SimpleInjectorAdapter.setup(%{event_queue: queue})

      # Simulate receiving external payload
      {:ok, event} =
        SimpleInjectorAdapter.to_event(%{
          type: :item_created,
          name: "Test Item",
          quantity: 5
        })

      EventQueue.push(context.event_queue, SimpleInjectorAdapter, event)

      # Verify event was pushed
      entries = EventQueue.drain(queue)

      assert length(entries) == 1
      assert hd(entries).event == event
      assert hd(entries).adapter_module == SimpleInjectorAdapter

      EventQueue.stop(queue)
    end
  end

  describe "behaviour info" do
    test "required callbacks are specified" do
      callbacks = Injector.behaviour_info(:callbacks)

      assert {:setup, 1} in callbacks
      assert {:teardown, 1} in callbacks
      assert {:to_event, 1} in callbacks
    end

    test "optional callbacks are declared" do
      optional = Injector.behaviour_info(:optional_callbacks)

      assert {:respond, 2} in optional
    end
  end
end
