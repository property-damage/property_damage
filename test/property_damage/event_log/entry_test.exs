defmodule PropertyDamage.EventLog.EntryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry

  # Test event struct
  defmodule TestEvent do
    defstruct [:data]
  end

  # Test injector module
  defmodule TestInjector do
  end

  describe "from_command/3" do
    test "creates entry with command source" do
      event = %TestEvent{data: "test"}
      entry = Entry.from_command(event, 0)

      assert entry.source == :command
      assert entry.event == event
      assert entry.command_index == 0
      assert entry.injector_adapter == nil
      assert is_integer(entry.timestamp)
    end

    test "uses provided command index" do
      entry = Entry.from_command(%TestEvent{}, 5)

      assert entry.command_index == 5
    end

    test "accepts custom timestamp" do
      entry = Entry.from_command(%TestEvent{}, 0, timestamp: 12345)

      assert entry.timestamp == 12345
    end
  end

  describe "from_injector/3" do
    test "creates entry with injector source" do
      event = %TestEvent{data: "test"}
      entry = Entry.from_injector(event, TestInjector)

      assert entry.source == :injector
      assert entry.event == event
      assert entry.command_index == nil
      assert entry.injector_adapter == TestInjector
      assert is_integer(entry.timestamp)
    end

    test "accepts custom timestamp" do
      entry = Entry.from_injector(%TestEvent{}, TestInjector, timestamp: 54321)

      assert entry.timestamp == 54321
    end
  end

  describe "command?/1" do
    test "returns true for command entries" do
      entry = Entry.from_command(%TestEvent{}, 0)

      assert Entry.command?(entry)
    end

    test "returns false for injector entries" do
      entry = Entry.from_injector(%TestEvent{}, TestInjector)

      refute Entry.command?(entry)
    end
  end

  describe "injector?/1" do
    test "returns true for injector entries" do
      entry = Entry.from_injector(%TestEvent{}, TestInjector)

      assert Entry.injector?(entry)
    end

    test "returns false for command entries" do
      entry = Entry.from_command(%TestEvent{}, 0)

      refute Entry.injector?(entry)
    end
  end

  describe "source distinction" do
    test "command and injector entries are distinguishable" do
      cmd_entry = Entry.from_command(%TestEvent{data: 1}, 0)
      inj_entry = Entry.from_injector(%TestEvent{data: 2}, TestInjector)

      # Can determine source from struct
      assert cmd_entry.source == :command
      assert inj_entry.source == :injector

      # Helper functions work
      assert Entry.command?(cmd_entry)
      assert Entry.injector?(inj_entry)
      refute Entry.command?(inj_entry)
      refute Entry.injector?(cmd_entry)
    end
  end

  describe "struct fields" do
    test "all expected fields exist" do
      entry = %Entry{}

      assert Map.has_key?(entry, :timestamp)
      assert Map.has_key?(entry, :command_index)
      assert Map.has_key?(entry, :event)
      assert Map.has_key?(entry, :source)
      assert Map.has_key?(entry, :injector_adapter)
    end
  end
end
