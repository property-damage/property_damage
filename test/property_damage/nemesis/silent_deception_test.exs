defmodule PropertyDamage.Nemesis.SilentDeceptionTest do
  @moduledoc """
  Regression for the silent-deception guard (P2): the network nemeses, which
  can only inject a real fault when Toxiproxy is configured, must report
  `simulated: true` when it is not, so a no-op fault can never masquerade as a
  real one.

  Proven to fail pre-fix: before the guard the events carried no `:simulated`
  field, so `Nemesis.simulated_event?/1` returned false for what was in fact a
  pure no-op.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Nemesis
  alias PropertyDamage.Nemesis.{NetworkLatency, NetworkPartition, PacketLoss}

  # No toxiproxy in the context => these nemeses inject nothing.
  @no_toxiproxy %{}

  describe "without Toxiproxy, network faults are flagged simulated" do
    test "NetworkLatency inject + restore" do
      cmd = %NetworkLatency{latency_ms: 100, jitter_ms: 0}

      {:ok, [injected]} = NetworkLatency.inject(cmd, @no_toxiproxy)
      assert injected.simulated == true
      assert Nemesis.simulated_event?(injected)

      {:ok, [restored]} =
        NetworkLatency.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          @no_toxiproxy
        )

      assert restored.simulated == true
    end

    test "NetworkPartition inject + restore" do
      cmd = %NetworkPartition{partition_type: :full}

      {:ok, [injected]} = NetworkPartition.inject(cmd, @no_toxiproxy)
      assert injected.simulated == true
      assert Nemesis.simulated_event?(injected)

      {:ok, [restored]} =
        NetworkPartition.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          @no_toxiproxy
        )

      assert restored.simulated == true
    end

    test "PacketLoss inject + restore" do
      cmd = %PacketLoss{loss_percent: 20}

      {:ok, [injected]} = PacketLoss.inject(cmd, @no_toxiproxy)
      assert injected.simulated == true
      assert Nemesis.simulated_event?(injected)

      {:ok, [restored]} =
        PacketLoss.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          @no_toxiproxy
        )

      assert restored.simulated == true
    end
  end

  describe "simulated_event?/1" do
    test "is false for real-effect nemesis events (no :simulated field)" do
      refute Nemesis.simulated_event?(%CPUStressInjected{intensity: 5})
      refute Nemesis.simulated_event?(%{some: :event})
    end

    test "honors an explicit simulated: false" do
      refute Nemesis.simulated_event?(%NetworkLatencyInjected{latency_ms: 1, simulated: false})
      assert Nemesis.simulated_event?(%NetworkLatencyInjected{latency_ms: 1, simulated: true})
    end
  end
end
