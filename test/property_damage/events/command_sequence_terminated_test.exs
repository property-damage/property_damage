defmodule PropertyDamage.Events.CommandSequenceTerminatedTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Events.CommandSequenceTerminated

  # Test command module
  defmodule CompletePayment do
  end

  describe "new/2" do
    test "creates event with reason" do
      event = CommandSequenceTerminated.new(:max_commands)

      assert event.reason == :max_commands
      assert event.total_commands == 0
      assert %DateTime{} = event.timestamp
    end

    test "accepts triggered_by option" do
      event =
        CommandSequenceTerminated.new(:model_terminated,
          triggered_by: {5, CompletePayment}
        )

      assert event.reason == :model_terminated
      assert event.triggered_by == {5, CompletePayment}
    end

    test "accepts total_commands option" do
      event =
        CommandSequenceTerminated.new(:max_commands,
          total_commands: 100
        )

      assert event.total_commands == 100
    end

    test "accepts custom timestamp" do
      timestamp = ~U[2025-01-15 10:30:00Z]
      event = CommandSequenceTerminated.new(:timeout, timestamp: timestamp)

      assert event.timestamp == timestamp
    end

    test "accepts all options together" do
      timestamp = ~U[2025-01-15 10:30:00Z]

      event =
        CommandSequenceTerminated.new(:model_terminated,
          triggered_by: {5, CompletePayment},
          total_commands: 6,
          timestamp: timestamp
        )

      assert event.reason == :model_terminated
      assert event.triggered_by == {5, CompletePayment}
      assert event.total_commands == 6
      assert event.timestamp == timestamp
    end
  end

  describe "reason predicates" do
    test "model_terminated? returns true for model termination" do
      event = CommandSequenceTerminated.new(:model_terminated)

      assert CommandSequenceTerminated.model_terminated?(event)
      refute CommandSequenceTerminated.max_commands?(event)
      refute CommandSequenceTerminated.timeout?(event)
    end

    test "max_commands? returns true for max commands" do
      event = CommandSequenceTerminated.new(:max_commands)

      assert CommandSequenceTerminated.max_commands?(event)
      refute CommandSequenceTerminated.model_terminated?(event)
      refute CommandSequenceTerminated.timeout?(event)
    end

    test "timeout? returns true for timeout" do
      event = CommandSequenceTerminated.new(:timeout)

      assert CommandSequenceTerminated.timeout?(event)
      refute CommandSequenceTerminated.model_terminated?(event)
      refute CommandSequenceTerminated.max_commands?(event)
    end
  end

  describe "reason_description/1" do
    test "describes model termination" do
      event = CommandSequenceTerminated.new(:model_terminated)

      assert CommandSequenceTerminated.reason_description(event) == "model terminated"
    end

    test "describes max commands" do
      event = CommandSequenceTerminated.new(:max_commands)

      assert CommandSequenceTerminated.reason_description(event) == "max commands reached"
    end

    test "describes timeout" do
      event = CommandSequenceTerminated.new(:timeout)

      assert CommandSequenceTerminated.reason_description(event) == "timeout"
    end

    test "describes injector signal" do
      event = CommandSequenceTerminated.new(:injector_signal)

      assert CommandSequenceTerminated.reason_description(event) == "injector signal"
    end
  end

  describe "struct fields" do
    test "all expected fields exist" do
      event = %CommandSequenceTerminated{}

      assert Map.has_key?(event, :reason)
      assert Map.has_key?(event, :triggered_by)
      assert Map.has_key?(event, :total_commands)
      assert Map.has_key?(event, :timestamp)
    end
  end
end
