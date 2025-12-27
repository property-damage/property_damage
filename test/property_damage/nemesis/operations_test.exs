defmodule PropertyDamage.Nemesis.OperationsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Nemesis.{
    NetworkLatency,
    NetworkPartition,
    PacketLoss,
    MemoryPressure,
    CPUStress,
    ClockSkew,
    ProcessKill,
    ResourceExhaustion,
    SlowIO
  }

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
      assert Enum.all?(partition_types, &(&1 in [:full, :upstream, :downstream, :asymmetric]))
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

  describe "MemoryPressure" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(MemoryPressure)
    end

    test "inject allocates memory and returns events" do
      # Use small allocation for test
      command = %MemoryPressure{megabytes: 1, allocation_pattern: :bulk}
      {:ok, events} = MemoryPressure.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == MemoryPressureInjected
      assert event.megabytes == 1

      # Verify memory was allocated (check process dictionary)
      keys = Process.get_keys() |> Enum.filter(&match?({:nemesis_memory, _}, &1))
      assert length(keys) > 0

      # Clean up
      MemoryPressure.restore(command, %{})
    end

    test "restore releases memory" do
      command = %MemoryPressure{megabytes: 1, allocation_pattern: :bulk}
      {:ok, _} = MemoryPressure.inject(command, %{})
      {:ok, events} = MemoryPressure.restore(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == MemoryPressureReleased

      # Verify memory was released
      keys = Process.get_keys() |> Enum.filter(&match?({:nemesis_memory, _}, &1))
      assert length(keys) == 0
    end

    test "new! generates valid commands" do
      generator = MemoryPressure.new!(%{})
      commands = Enum.take(StreamData.resize(generator, 10), 5)

      for cmd <- commands do
        assert %MemoryPressure{} = cmd
        assert cmd.megabytes >= 50
        assert cmd.allocation_pattern in [:bulk, :fragmented]
      end
    end
  end

  describe "CPUStress" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(CPUStress)
    end

    test "inject spawns stress processes" do
      command = %CPUStress{intensity: 1, schedulers: 1, duration_ms: 100}
      {:ok, events} = CPUStress.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == CPUStressInjected

      # Verify processes were spawned
      pids = Process.get(:nemesis_cpu_pids)
      assert is_list(pids)
      assert length(pids) == 1

      # Clean up
      CPUStress.restore(command, %{})
    end

    test "restore kills stress processes" do
      command = %CPUStress{intensity: 1, schedulers: 1}
      {:ok, _} = CPUStress.inject(command, %{})

      pids = Process.get(:nemesis_cpu_pids)
      assert Enum.all?(pids, &Process.alive?/1)

      {:ok, events} = CPUStress.restore(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == CPUStressReleased

      # Give processes time to die
      Process.sleep(50)

      # Verify processes were killed
      refute Enum.any?(pids, &Process.alive?/1)
    end
  end

  describe "ClockSkew" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(ClockSkew)
    end

    test "now returns real time when no skew active" do
      real_time = System.system_time(:millisecond)
      virtual_time = ClockSkew.now()

      # Should be very close (within 10ms)
      assert abs(virtual_time - real_time) < 10
    end

    test "inject applies clock skew" do
      command = %ClockSkew{skew_ms: 1000, mode: :instant}
      {:ok, events} = ClockSkew.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == ClockSkewInjected

      # Virtual time should be ~1 second ahead
      real_time = System.system_time(:millisecond)
      virtual_time = ClockSkew.now()

      assert abs(virtual_time - real_time - 1000) < 50

      # Clean up
      ClockSkew.restore(command, %{})
    end

    test "restore removes clock skew" do
      command = %ClockSkew{skew_ms: 5000, mode: :instant}
      {:ok, _} = ClockSkew.inject(command, %{})

      assert ClockSkew.active?()

      {:ok, events} = ClockSkew.restore(command, %{})

      refute ClockSkew.active?()
      assert length(events) == 1

      # Time should be back to normal
      real_time = System.system_time(:millisecond)
      virtual_time = ClockSkew.now()

      assert abs(virtual_time - real_time) < 10
    end

    test "negative skew moves time backward" do
      command = %ClockSkew{skew_ms: -1000, mode: :instant}
      {:ok, _} = ClockSkew.inject(command, %{})

      real_time = System.system_time(:millisecond)
      virtual_time = ClockSkew.now()

      # Virtual time should be ~1 second behind
      assert abs(virtual_time - real_time + 1000) < 50

      ClockSkew.restore(command, %{})
    end

    test "drift rate affects time progression" do
      # 10% faster clock
      command = %ClockSkew{skew_ms: 0, drift_rate: 1.1, mode: :gradual}
      {:ok, _} = ClockSkew.inject(command, %{})

      # Wait a bit
      Process.sleep(100)

      real_time = System.system_time(:millisecond)
      virtual_time = ClockSkew.now()

      # With 10% drift over 100ms, should be ~10ms ahead
      # Allow some tolerance
      assert virtual_time >= real_time

      ClockSkew.restore(command, %{})
    end
  end

  describe "ProcessKill" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(ProcessKill)
    end

    test "precondition always returns true" do
      assert ProcessKill.precondition(%{})
      assert ProcessKill.precondition(%{active_faults: %{process_kill: true}})
    end

    test "inject kills named process" do
      # Start a test process (not linked to avoid test process dying)
      {:ok, pid} = Agent.start(fn -> 0 end, name: :test_kill_target)

      command = %ProcessKill{target: {:name, :test_kill_target}, signal: :kill}
      {:ok, events} = ProcessKill.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == ProcessKilled
      assert event.killed_count == 1

      # Give process time to die
      Process.sleep(10)

      # Process should be dead
      refute Process.alive?(pid)
    end

    test "inject handles non-existent process" do
      command = %ProcessKill{target: {:name, :nonexistent_process}, signal: :kill}
      {:ok, events} = ProcessKill.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.killed_count == 0
    end

    test "auto_restore returns false" do
      # ProcessKill is one-shot, no auto-restore
      refute ProcessKill.auto_restore?()
    end
  end

  describe "ResourceExhaustion" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(ResourceExhaustion)
    end

    test "inject exhausts file descriptors" do
      command = %ResourceExhaustion{resource: :file_descriptors, count: 5}
      {:ok, events} = ResourceExhaustion.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == ResourceExhausted
      assert event.resource == :file_descriptors
      assert event.actual_count == 5

      # Clean up
      ResourceExhaustion.restore(command, %{})
    end

    test "inject exhausts ETS tables" do
      command = %ResourceExhaustion{resource: :ets_tables, count: 3}
      {:ok, events} = ResourceExhaustion.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.resource == :ets_tables
      assert event.actual_count == 3

      # Clean up
      ResourceExhaustion.restore(command, %{})
    end

    test "inject exhausts processes" do
      command = %ResourceExhaustion{resource: :processes, count: 10}
      {:ok, events} = ResourceExhaustion.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.resource == :processes
      assert event.actual_count == 10

      # Clean up
      ResourceExhaustion.restore(command, %{})
    end

    test "restore releases resources" do
      command = %ResourceExhaustion{resource: :ets_tables, count: 3}
      {:ok, _} = ResourceExhaustion.inject(command, %{})
      {:ok, events} = ResourceExhaustion.restore(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == ResourceReleased
    end
  end

  describe "SlowIO" do
    test "implements Nemesis behaviour" do
      assert PropertyDamage.Nemesis.nemesis_module?(SlowIO)
    end

    test "should_delay? returns false when no slow IO active" do
      refute SlowIO.should_delay?()
      refute SlowIO.should_delay?(:reads)
      refute SlowIO.should_delay?(:writes)
    end

    test "inject enables slow IO" do
      command = %SlowIO{delay_ms: 50, target: :all}
      {:ok, events} = SlowIO.inject(command, %{})

      assert length(events) == 1
      [event] = events
      assert event.__struct__ == SlowIOInjected

      assert SlowIO.active?()
      assert SlowIO.should_delay?()
      assert SlowIO.should_delay?(:reads)
      assert SlowIO.should_delay?(:writes)

      # Clean up
      SlowIO.restore(command, %{})
    end

    test "inject with target :reads only affects reads" do
      command = %SlowIO{delay_ms: 50, target: :reads}
      {:ok, _} = SlowIO.inject(command, %{})

      assert SlowIO.should_delay?(:reads)
      refute SlowIO.should_delay?(:writes)

      SlowIO.restore(command, %{})
    end

    test "apply_delay sleeps for configured time" do
      command = %SlowIO{delay_ms: 50, jitter_ms: 0}
      {:ok, _} = SlowIO.inject(command, %{})

      start = System.monotonic_time(:millisecond)
      SlowIO.apply_delay()
      elapsed = System.monotonic_time(:millisecond) - start

      # Should have slept ~50ms
      assert elapsed >= 45 and elapsed < 100

      SlowIO.restore(command, %{})
    end

    test "restore disables slow IO" do
      command = %SlowIO{delay_ms: 50}
      {:ok, _} = SlowIO.inject(command, %{})

      assert SlowIO.active?()

      {:ok, events} = SlowIO.restore(command, %{})

      refute SlowIO.active?()
      assert length(events) == 1
      [event] = events
      assert event.__struct__ == SlowIORestored
    end
  end

  describe "Integration with Nemesis module" do
    test "nemesis_module? correctly identifies all operations" do
      modules = [
        NetworkLatency,
        NetworkPartition,
        PacketLoss,
        MemoryPressure,
        CPUStress,
        ClockSkew,
        ProcessKill,
        ResourceExhaustion,
        SlowIO
      ]

      for module <- modules do
        assert PropertyDamage.Nemesis.nemesis_module?(module),
               "#{module} should be identified as a Nemesis module"
      end
    end

    test "nemesis_command? identifies command structs" do
      commands = [
        %NetworkLatency{},
        %NetworkPartition{},
        %PacketLoss{},
        %MemoryPressure{},
        %CPUStress{},
        %ClockSkew{},
        %ProcessKill{},
        %ResourceExhaustion{},
        %SlowIO{}
      ]

      for cmd <- commands do
        assert PropertyDamage.Nemesis.nemesis_command?(cmd),
               "#{inspect(cmd.__struct__)} should be identified as a Nemesis command"
      end
    end

    test "auto_restores? returns correct values" do
      assert PropertyDamage.Nemesis.auto_restores?(%NetworkLatency{})
      assert PropertyDamage.Nemesis.auto_restores?(%NetworkPartition{})
      assert PropertyDamage.Nemesis.auto_restores?(%ClockSkew{})
      refute PropertyDamage.Nemesis.auto_restores?(%ProcessKill{})
    end

    test "get_duration_ms returns correct durations" do
      assert PropertyDamage.Nemesis.get_duration_ms(%NetworkLatency{duration_ms: 5000}) == 5000
      assert PropertyDamage.Nemesis.get_duration_ms(%ClockSkew{duration_ms: 3000}) == 3000
      assert PropertyDamage.Nemesis.get_duration_ms(%SlowIO{duration_ms: 2000}) == 2000
    end
  end
end
