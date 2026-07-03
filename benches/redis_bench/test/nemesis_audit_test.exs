defmodule RedisBench.NemesisAuditTest do
  @moduledoc """
  Nemesis audit: for each built-in nemesis, prove it either REALLY injects its
  fault (the SUT's observable behavior changes between injected and not, a
  differential) or is honestly reported as simulated.

  The built-in nemeses fault the SUT's network path via Toxiproxy. Earlier
  versions also shipped host-effect / cooperative / one-shot nemeses that acted
  on the local BEAM rather than the SUT; those were removed (DR-032) because
  they tested the harness, not the System Under Test. So this audit covers the
  network trio:

    * Network (NetworkLatency / NetworkPartition / PacketLoss) — real via the
      bench's Toxiproxy proxy (differential: round-trip time / connectivity
      through the proxy changes), and honestly `simulated: true` without it.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Nemesis
  alias PropertyDamage.Nemesis.{NetworkLatency, NetworkPartition, PacketLoss}

  alias RedisBench.Toxiproxy

  # Context that points the network nemeses at the bench's real Toxiproxy proxy.
  defp toxiproxy_ctx do
    %{toxiproxy: %{proxy_name: Toxiproxy.proxy_name(), api_url: Toxiproxy.api_url()}}
  end

  describe "network nemeses (real via Toxiproxy, honest simulated without)" do
    setup do
      :ok = Toxiproxy.ensure_clean_proxy()
      on_exit(fn -> Toxiproxy.ensure_clean_proxy() end)
      :ok
    end

    test "NetworkLatency really slows the proxy, and restore lifts it" do
      {:ok, clean_ms} = Toxiproxy.probe_ping_ms()
      assert clean_ms < 100

      cmd = %NetworkLatency{latency_ms: 250, jitter_ms: 0}
      {:ok, [injected]} = NetworkLatency.inject(cmd, toxiproxy_ctx())
      assert injected.simulated == false
      refute Nemesis.simulated_event?(injected)

      {:ok, laggy_ms} = Toxiproxy.probe_ping_ms()
      assert laggy_ms >= 200, "real latency not observed (#{laggy_ms}ms vs #{clean_ms}ms)"

      {:ok, [_restored]} =
        NetworkLatency.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          toxiproxy_ctx()
        )

      {:ok, restored_ms} = Toxiproxy.probe_ping_ms()
      assert restored_ms < 100, "restore did not lift latency (#{restored_ms}ms)"
    end

    test "NetworkLatency without Toxiproxy: a no-op that masquerades as a real fault" do
      {:ok, clean_ms} = Toxiproxy.probe_ping_ms()

      # The deception, behaviorally. inject reports success with an event that
      # looks exactly like the real injection above (same struct, same
      # latency_ms)...
      {:ok, [injected]} = NetworkLatency.inject(%NetworkLatency{latency_ms: 250}, %{})
      assert injected.__struct__ == NetworkLatencyInjected
      assert injected.latency_ms == 250

      # ...yet the SUT is completely unaffected: the round-trip is unchanged, so
      # the "fault" did nothing.
      {:ok, sim_ms} = Toxiproxy.probe_ping_ms()
      assert sim_ms < 100, "a simulated fault must not actually slow the SUT"
      assert_in_delta sim_ms, clean_ms, 80

      # The ONLY thing that tells this no-op apart from the real fault is the
      # simulated marker (the P2 fix). Pre-fix the two were indistinguishable.
      assert injected.simulated == true
    end

    test "NetworkPartition really cuts the proxy, and restore heals it" do
      assert {:ok, _} = Toxiproxy.probe_ping_ms()

      cmd = %NetworkPartition{partition_type: :full}
      {:ok, [injected]} = NetworkPartition.inject(cmd, toxiproxy_ctx())
      assert injected.simulated == false

      assert {:error, _} = Toxiproxy.probe_ping_ms(500),
             "real partition should make the proxy unreachable"

      {:ok, [_restored]} =
        NetworkPartition.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          toxiproxy_ctx()
        )

      assert {:ok, _} = Toxiproxy.probe_ping_ms(), "restore did not heal the partition"
    end

    test "NetworkPartition :full cuts BOTH directions (DR-038: two directional toxics)" do
      cmd = %NetworkPartition{partition_type: :full}
      {:ok, [injected]} = NetworkPartition.inject(cmd, toxiproxy_ctx())
      assert injected.simulated == false

      # The pre-DR-038 :full sent ONE unqualified bandwidth toxic (downstream by
      # Toxiproxy default), leaving the upstream open. A real full partition
      # installs a rate-0 bandwidth toxic on EACH stream.
      {:ok, toxics} = Toxiproxy.list_toxics()
      streams = toxics |> Enum.map(& &1["stream"]) |> Enum.sort()
      assert streams == ["downstream", "upstream"], "full partition must block both directions"

      for toxic <- toxics do
        assert toxic["type"] == "bandwidth"
        assert toxic["attributes"]["rate"] == 0
      end

      # Restore removes both toxics (two DELETEs), leaving the proxy clean.
      {:ok, [_restored]} =
        NetworkPartition.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          toxiproxy_ctx()
        )

      assert {:ok, []} = Toxiproxy.list_toxics(), "restore must remove both partition toxics"
    end

    test "NetworkPartition without Toxiproxy: a no-op that masquerades as a real fault" do
      # Reports success with a real-looking partition event...
      {:ok, [injected]} = NetworkPartition.inject(%NetworkPartition{partition_type: :full}, %{})
      assert injected.__struct__ == NetworkPartitioned
      assert injected.partition_type == :full

      # ...but the proxy is still fully reachable: nothing was cut. (The real
      # injection above made probe_ping_ms/1 error.)
      assert {:ok, _} = Toxiproxy.probe_ping_ms()

      # Only the marker distinguishes the no-op from the real partition.
      assert injected.simulated == true
    end

    test "PacketLoss really disrupts the proxy, and restore clears it" do
      assert {:ok, _} = Toxiproxy.probe_ping_ms()

      # 100% loss => toxicity 1.0 => every connection through the proxy stalls.
      cmd = %PacketLoss{loss_percent: 100}
      {:ok, [injected]} = PacketLoss.inject(cmd, toxiproxy_ctx())
      assert injected.simulated == false

      assert {:error, _} = Toxiproxy.probe_ping_ms(500),
             "real packet loss at 100% should disrupt the connection"

      {:ok, [_restored]} =
        PacketLoss.restore(
          %{cmd | injected_at: System.monotonic_time(:millisecond)},
          toxiproxy_ctx()
        )

      assert {:ok, _} = Toxiproxy.probe_ping_ms(), "restore did not clear packet loss"
    end

    test "PacketLoss without Toxiproxy: a no-op that masquerades as a real fault" do
      # Reports success with a real-looking packet-loss event...
      {:ok, [injected]} = PacketLoss.inject(%PacketLoss{loss_percent: 100}, %{})
      assert injected.__struct__ == PacketLossInjected
      assert injected.loss_percent == 100

      # ...but the connection works fine: nothing was disrupted. (The real
      # injection above made probe_ping_ms/1 error.)
      assert {:ok, _} = Toxiproxy.probe_ping_ms()

      # Only the marker distinguishes the no-op from real packet loss.
      assert injected.simulated == true
    end
  end
end
