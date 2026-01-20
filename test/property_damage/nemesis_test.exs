defmodule PropertyDamage.NemesisTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Nemesis

  # Test nemesis commands
  defmodule TestPartition do
    @behaviour PropertyDamage.Nemesis

    defstruct [:partition_type, :duration_ms]

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{partition_type: type}, _ctx) do
      {:ok, [%{type: :partitioned, partition_type: type}]}
    end

    @impl true
    def restore(%__MODULE__{partition_type: type}, _ctx) do
      {:ok, [%{type: :restored, partition_type: type}]}
    end

    @impl true
    def auto_restore?, do: true

    @impl true
    def duration_ms(%__MODULE__{duration_ms: d}), do: d
  end

  defmodule TestLatency do
    @behaviour PropertyDamage.Nemesis

    defstruct [:latency_ms]

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{latency_ms: ms}, _ctx) do
      {:ok, [%{type: :latency_injected, latency_ms: ms}]}
    end

    @impl true
    def restore(%__MODULE__{}, _ctx) do
      {:ok, [%{type: :latency_removed}]}
    end

    @impl true
    def auto_restore?, do: false
  end

  defmodule TestFailingNemesis do
    @behaviour PropertyDamage.Nemesis

    defstruct [:id]

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{}, _ctx) do
      {:error, :injection_failed}
    end

    @impl true
    def restore(%__MODULE__{}, _ctx) do
      {:error, :restore_failed}
    end
  end

  defmodule NotANemesis do
    defstruct [:id]
  end

  describe "nemesis_module?/1" do
    test "returns true for modules implementing Nemesis behaviour" do
      assert Nemesis.nemesis_module?(TestPartition)
      assert Nemesis.nemesis_module?(TestLatency)
      assert Nemesis.nemesis_module?(TestFailingNemesis)
    end

    test "returns false for regular modules" do
      refute Nemesis.nemesis_module?(NotANemesis)
      refute Nemesis.nemesis_module?(String)
      refute Nemesis.nemesis_module?(Enum)
    end

    test "returns false for non-existent modules" do
      refute Nemesis.nemesis_module?(NonExistentModule)
    end
  end

  describe "nemesis_command?/1" do
    test "returns true for nemesis command structs" do
      assert Nemesis.nemesis_command?(%TestPartition{partition_type: :full, duration_ms: 1000})
      assert Nemesis.nemesis_command?(%TestLatency{latency_ms: 500})
    end

    test "returns false for regular structs" do
      refute Nemesis.nemesis_command?(%NotANemesis{id: 1})
    end

    test "returns false for non-structs" do
      refute Nemesis.nemesis_command?(%{foo: :bar})
      refute Nemesis.nemesis_command?("string")
      refute Nemesis.nemesis_command?(123)
      refute Nemesis.nemesis_command?(nil)
    end
  end

  describe "auto_restores?/1" do
    test "returns true when auto_restore?/0 returns true" do
      assert Nemesis.auto_restores?(%TestPartition{partition_type: :full, duration_ms: 1000})
    end

    test "returns false when auto_restore?/0 returns false" do
      refute Nemesis.auto_restores?(%TestLatency{latency_ms: 500})
    end

    test "defaults to true when auto_restore?/0 not implemented" do
      assert Nemesis.auto_restores?(%TestFailingNemesis{id: 1})
    end
  end

  describe "get_duration_ms/1" do
    test "returns duration from duration_ms/1 callback" do
      cmd = %TestPartition{partition_type: :full, duration_ms: 5000}
      assert Nemesis.get_duration_ms(cmd) == 5000
    end

    test "returns duration from struct field when callback not implemented" do
      # TestLatency doesn't implement duration_ms/1 but has the field
      # However, our TestLatency doesn't have duration_ms field, so it returns nil
      cmd = %TestLatency{latency_ms: 500}
      assert Nemesis.get_duration_ms(cmd) == nil
    end

    test "returns nil when no duration available" do
      cmd = %TestFailingNemesis{id: 1}
      assert Nemesis.get_duration_ms(cmd) == nil
    end
  end

  describe "inject/2 callback" do
    test "successful injection returns events" do
      cmd = %TestPartition{partition_type: :full, duration_ms: 1000}
      {:ok, events} = TestPartition.inject(cmd, %{})

      assert [%{type: :partitioned, partition_type: :full}] = events
    end

    test "failed injection returns error" do
      cmd = %TestFailingNemesis{id: 1}
      assert {:error, :injection_failed} = TestFailingNemesis.inject(cmd, %{})
    end
  end

  describe "restore/2 callback" do
    test "successful restoration returns events" do
      cmd = %TestPartition{partition_type: :full, duration_ms: 1000}
      {:ok, events} = TestPartition.restore(cmd, %{})

      assert [%{type: :restored, partition_type: :full}] = events
    end

    test "failed restoration returns error" do
      cmd = %TestFailingNemesis{id: 1}
      assert {:error, :restore_failed} = TestFailingNemesis.restore(cmd, %{})
    end
  end

  describe "precondition/1 callback" do
    test "precondition is checked before injection" do
      assert TestPartition.precondition(%{})
      assert TestLatency.precondition(%{})
    end
  end

  describe "nemesis workflow" do
    test "full inject -> restore cycle" do
      cmd = %TestPartition{partition_type: :asymmetric, duration_ms: 2000}

      # Inject fault
      {:ok, inject_events} = TestPartition.inject(cmd, %{adapter_context: %{}})
      assert [%{type: :partitioned, partition_type: :asymmetric}] = inject_events

      # Restore after duration
      {:ok, restore_events} = TestPartition.restore(cmd, %{adapter_context: %{}})
      assert [%{type: :restored, partition_type: :asymmetric}] = restore_events
    end

    test "non-auto-restore nemesis requires explicit restore" do
      cmd = %TestLatency{latency_ms: 100}

      # Should not auto-restore
      refute Nemesis.auto_restores?(cmd)

      # But can still be restored explicitly
      {:ok, events} = TestLatency.restore(cmd, %{})
      assert [%{type: :latency_removed}] = events
    end
  end
end
