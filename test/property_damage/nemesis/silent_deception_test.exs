defmodule PropertyDamage.Nemesis.SilentDeceptionTest do
  @moduledoc """
  Regression for the silent-deception guard (P2): the network nemeses, which
  can only inject a real fault when Toxiproxy is configured, must report
  `simulated: true` when it is not, so a no-op fault can never masquerade as a
  real one.

  Note on what this test does and does not prove. The P2 fix *adds* an honest
  channel (the `:simulated` marker) where none existed, so any test that
  verifies it must reference the new field and therefore cannot run against the
  old code at all (it fails to compile, which is a structural artifact, not a
  behavioral catch). This file is therefore a forward contract guard: it locks
  in the marker so a future network nemesis, or a revert, can't reintroduce the
  silent no-op. The *behavioral* proof of the deception (these nemeses report
  success while leaving the SUT untouched, and only the marker tells the no-op
  apart from a real fault) needs a live SUT and lives in the Redis bench's
  nemesis audit (`benches/redis_bench/test/nemesis_audit_test.exs`).
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
