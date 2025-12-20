defmodule PropertyDamage.EventQueueTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.EventQueue

  # Test injector module
  defmodule TestInjector do
  end

  defmodule AnotherInjector do
  end

  # Test event
  defmodule TestEvent do
    defstruct [:data]
  end

  describe "start_link/0 and stop/1" do
    test "starts and stops cleanly" do
      {:ok, queue} = EventQueue.start_link()
      assert is_pid(queue)
      assert Process.alive?(queue)

      :ok = EventQueue.stop(queue)
      refute Process.alive?(queue)
    end

    test "starts with options" do
      {:ok, queue} = EventQueue.start_link(name: :test_queue)
      assert Process.whereis(:test_queue) == queue

      :ok = EventQueue.stop(queue)
    end
  end

  describe "push/3" do
    test "adds entry to queue" do
      {:ok, queue} = EventQueue.start_link()
      event = %TestEvent{data: "test"}

      :ok = EventQueue.push(queue, TestInjector, event)

      entries = EventQueue.peek(queue)
      assert length(entries) == 1
      assert hd(entries).event == event
      assert hd(entries).adapter_module == TestInjector

      EventQueue.stop(queue)
    end

    test "includes timestamp" do
      {:ok, queue} = EventQueue.start_link()
      before = System.monotonic_time(:millisecond)

      :ok = EventQueue.push(queue, TestInjector, %TestEvent{})

      [entry] = EventQueue.peek(queue)
      assert is_integer(entry.timestamp)
      assert entry.timestamp >= before

      EventQueue.stop(queue)
    end

    test "preserves order" do
      {:ok, queue} = EventQueue.start_link()

      EventQueue.push(queue, TestInjector, %TestEvent{data: 1})
      EventQueue.push(queue, TestInjector, %TestEvent{data: 2})
      EventQueue.push(queue, TestInjector, %TestEvent{data: 3})

      entries = EventQueue.peek(queue)
      assert Enum.map(entries, & &1.event.data) == [1, 2, 3]

      EventQueue.stop(queue)
    end
  end

  describe "drain/1" do
    test "returns all entries and clears queue" do
      {:ok, queue} = EventQueue.start_link()
      EventQueue.push(queue, TestInjector, %TestEvent{data: 1})
      EventQueue.push(queue, TestInjector, %TestEvent{data: 2})

      entries = EventQueue.drain(queue)

      assert length(entries) == 2
      assert Enum.map(entries, & &1.event.data) == [1, 2]

      # Queue should be empty now
      assert EventQueue.drain(queue) == []

      EventQueue.stop(queue)
    end

    test "returns empty list when queue is empty" do
      {:ok, queue} = EventQueue.start_link()

      entries = EventQueue.drain(queue)

      assert entries == []

      EventQueue.stop(queue)
    end
  end

  describe "peek/1" do
    test "returns entries without removing them" do
      {:ok, queue} = EventQueue.start_link()
      EventQueue.push(queue, TestInjector, %TestEvent{data: 1})

      entries1 = EventQueue.peek(queue)
      entries2 = EventQueue.peek(queue)

      assert entries1 == entries2
      assert length(entries1) == 1

      EventQueue.stop(queue)
    end
  end

  describe "empty?/1" do
    test "returns true for empty queue" do
      {:ok, queue} = EventQueue.start_link()

      assert EventQueue.empty?(queue)

      EventQueue.stop(queue)
    end

    test "returns false when events exist" do
      {:ok, queue} = EventQueue.start_link()
      EventQueue.push(queue, TestInjector, %TestEvent{})

      refute EventQueue.empty?(queue)

      EventQueue.stop(queue)
    end
  end

  describe "size/1" do
    test "returns zero for empty queue" do
      {:ok, queue} = EventQueue.start_link()

      assert EventQueue.size(queue) == 0

      EventQueue.stop(queue)
    end

    test "returns correct count" do
      {:ok, queue} = EventQueue.start_link()
      EventQueue.push(queue, TestInjector, %TestEvent{})
      EventQueue.push(queue, TestInjector, %TestEvent{})
      EventQueue.push(queue, TestInjector, %TestEvent{})

      assert EventQueue.size(queue) == 3

      EventQueue.stop(queue)
    end
  end

  describe "multiple adapters" do
    test "tracks adapter_module for each event" do
      {:ok, queue} = EventQueue.start_link()

      EventQueue.push(queue, TestInjector, %TestEvent{data: "from_test"})
      EventQueue.push(queue, AnotherInjector, %TestEvent{data: "from_another"})

      entries = EventQueue.drain(queue)

      assert Enum.at(entries, 0).adapter_module == TestInjector
      assert Enum.at(entries, 1).adapter_module == AnotherInjector

      EventQueue.stop(queue)
    end
  end
end
