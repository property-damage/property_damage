defmodule PropertyDamage.Nemesis.OperationsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Nemesis.{NetworkLatency, NetworkPartition, PacketLoss}

  describe "NetworkLatency" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(NetworkLatency)
    end

    test "precondition returns true when no latency active" do
      assert NetworkLatency.precondition(%{})
      assert NetworkLatency.precondition(%{active_faults: %{}})
    end

    test "precondition returns false when latency already active" do
      state = %{active_faults: %{network_latency: true}}
      refute NetworkLatency.precondition(state)
    end

    test "inject returns ok with events" do
      command = %NetworkLatency{latency_ms: 100, jitter_ms: 10}
      {:ok, events} = NetworkLatency.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == NetworkLatencyInjected
      assert event.latency_ms == 100
      assert event.jitter_ms == 10
    end

    test "restore returns ok with events" do
      command = %NetworkLatency{latency_ms: 100, injected_at: System.monotonic_time(:millisecond)}
      {:ok, events} = NetworkLatency.restore(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == NetworkLatencyRestored
    end

    test "auto_restore? returns true" do
      assert NetworkLatency.auto_restore?()
    end

    test "duration_ms returns configured duration" do
      command = %NetworkLatency{duration_ms: 3000}
      assert NetworkLatency.duration_ms(command) == 3000
    end

    test "new! generates valid command" do
      generator = NetworkLatency.new!(%{})
      commands = Enum.take(StreamData.resize(generator, 10), 5)

      for cmd <- commands do
        assert %NetworkLatency{} = cmd
        assert cmd.latency_ms >= 50
        assert cmd.jitter_ms >= 0
        assert cmd.duration_ms >= 1000
      end
    end
  end

  describe "NetworkPartition" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(NetworkPartition)
    end

    test "precondition returns true when no partition active" do
      assert NetworkPartition.precondition(%{})
    end

    test "inject returns ok with events" do
      command = %NetworkPartition{partition_type: :full}
      {:ok, events} = NetworkPartition.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == NetworkPartitioned
      assert event.partition_type == :full
    end

    test "restore returns ok with events" do
      command = %NetworkPartition{
        partition_type: :full,
        injected_at: System.monotonic_time(:millisecond)
      }

      {:ok, events} = NetworkPartition.restore(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == NetworkPartitionHealed
    end

    test "new! generates valid commands with different partition types" do
      generator = NetworkPartition.new!(%{})
      commands = Enum.take(StreamData.resize(generator, 10), 20)

      partition_types = Enum.map(commands, & &1.partition_type) |> Enum.uniq()
      assert length(partition_types) > 1

      for type <- partition_types do
        assert type in [:full, :upstream, :downstream],
               "unexpected partition type: #{inspect(type)}"
      end
    end
  end

  describe "PacketLoss" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(PacketLoss)
    end

    test "inject returns ok with events" do
      command = %PacketLoss{loss_percent: 20}
      {:ok, events} = PacketLoss.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == PacketLossInjected
      assert event.loss_percent == 20
    end

    test "new! generates valid commands" do
      generator = PacketLoss.new!(%{})
      commands = Enum.take(StreamData.resize(generator, 10), 5)

      for cmd <- commands do
        assert %PacketLoss{} = cmd
        assert cmd.loss_percent >= 5 and cmd.loss_percent <= 50
      end
    end
  end
end
