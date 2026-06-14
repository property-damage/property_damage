defmodule RedisBench.NemesisAuditTest do
  @moduledoc """
  The 6d nemesis audit: for each of the 10 built-in nemesis implementations,
  prove it either REALLY injects its fault (the SUT's observable behavior
  changes between injected and not, a differential) or is honestly reported as
  simulated.

  Per the Phase 2 inventory this surface was "chaos theater": only CPUStress was
  known to inject; the network trio silently no-opped without Toxiproxy and the
  rest were unaudited. This test resolves every one of them:

    * Network (NetworkLatency / NetworkPartition / PacketLoss) — real via the
      bench's Toxiproxy proxy (differential: round-trip time / connectivity
      through the proxy changes), and honestly `simulated: true` without it.
    * Host-effect (CPUStress / MemoryPressure / ResourceExhaustion /
      ProcessKill) — real BEAM/host effects (live stress processes, allocated
      memory, ETS tables, a killed pid), and lifted by restore.
    * Cooperative (ClockSkew / SlowIO / CertificateExpiry) — real installed
      state observable through each one's public API, cleared by restore.

  inject/2 and restore/2 run in the test process here, so the
  process-dictionary-backed nemeses install and clean up in this process.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Nemesis

  alias PropertyDamage.Nemesis.{
    CertificateExpiry,
    ClockSkew,
    CPUStress,
    MemoryPressure,
    NetworkLatency,
    NetworkPartition,
    PacketLoss,
    ProcessKill,
    ResourceExhaustion,
    SlowIO
  }

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

    test "NetworkLatency without Toxiproxy is honestly simulated" do
      {:ok, [injected]} = NetworkLatency.inject(%NetworkLatency{latency_ms: 250}, %{})
      assert injected.simulated == true

      {:ok, ms} = Toxiproxy.probe_ping_ms()
      assert ms < 100, "a simulated fault must not actually slow the SUT"
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

    test "NetworkPartition without Toxiproxy is honestly simulated" do
      {:ok, [injected]} = NetworkPartition.inject(%NetworkPartition{partition_type: :full}, %{})
      assert injected.simulated == true
      assert {:ok, _} = Toxiproxy.probe_ping_ms()
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

    test "PacketLoss without Toxiproxy is honestly simulated" do
      {:ok, [injected]} = PacketLoss.inject(%PacketLoss{loss_percent: 100}, %{})
      assert injected.simulated == true
      assert {:ok, _} = Toxiproxy.probe_ping_ms()
    end
  end

  describe "host-effect nemeses (always real)" do
    test "CPUStress spawns live stress processes that restore kills" do
      cmd = %CPUStress{intensity: 1, schedulers: 1, duration_ms: 5000}
      {:ok, [event]} = CPUStress.inject(cmd, %{})
      refute Nemesis.simulated_event?(event)

      pids = Process.get(:nemesis_cpu_pids)
      assert is_list(pids) and pids != []
      assert Enum.all?(pids, &Process.alive?/1), "stress processes were not spawned"

      {:ok, _} = CPUStress.restore(cmd, %{})
      Process.sleep(30)
      assert Enum.all?(pids, &(not Process.alive?(&1))), "restore did not kill stress processes"
    end

    test "MemoryPressure really allocates memory that restore frees" do
      before = :erlang.memory(:total)

      cmd = %MemoryPressure{megabytes: 50, allocation_pattern: :bulk, duration_ms: 5000}
      {:ok, _} = MemoryPressure.inject(cmd, %{})

      after_inject = :erlang.memory(:total)
      assert after_inject - before >= 40_000_000, "memory was not actually allocated"
      assert Enum.any?(Process.get_keys(), &match?({:nemesis_memory, _}, &1))

      {:ok, _} = MemoryPressure.restore(cmd, %{})

      refute Enum.any?(Process.get_keys(), &match?({:nemesis_memory, _}, &1)),
             "restore did not release the allocation"
    end

    test "ResourceExhaustion really creates ETS tables that restore releases" do
      before = length(:ets.all())

      cmd = %ResourceExhaustion{resource: :ets_tables, count: 20, duration_ms: 5000}
      {:ok, [event]} = ResourceExhaustion.inject(cmd, %{})

      after_inject = length(:ets.all())
      assert after_inject - before >= 15, "ETS tables were not actually created"
      assert event.actual_count >= 15

      {:ok, _} = ResourceExhaustion.restore(cmd, %{})
      assert length(:ets.all()) <= before + 2, "restore did not release the ETS tables"
    end

    test "ProcessKill really kills its target" do
      victim = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(victim)
      assert Process.alive?(victim)

      cmd = %ProcessKill{target: {:pid, victim}, signal: :kill}
      {:ok, [event]} = ProcessKill.inject(cmd, %{})
      assert event.killed_count == 1

      assert_receive {:DOWN, ^ref, :process, ^victim, _reason}, 1000
      refute Process.alive?(victim)
    end
  end

  describe "cooperative nemeses (real state via public API)" do
    test "ClockSkew really shifts the virtual clock and restore resets it" do
      refute ClockSkew.active?()

      cmd = %ClockSkew{skew_ms: 60_000, mode: :instant, duration_ms: 5000}
      {:ok, _} = ClockSkew.inject(cmd, %{})

      assert ClockSkew.active?()
      skew = ClockSkew.now() - System.system_time(:millisecond)
      assert skew >= 55_000, "virtual clock was not skewed forward (#{skew}ms)"

      {:ok, _} = ClockSkew.restore(cmd, %{})
      refute ClockSkew.active?()
      assert abs(ClockSkew.now() - System.system_time(:millisecond)) < 1000
    end

    test "SlowIO really delays I/O and restore removes it" do
      refute SlowIO.should_delay?()

      cmd = %SlowIO{delay_ms: 200, jitter_ms: 0, target: :all, duration_ms: 5000}
      {:ok, _} = SlowIO.inject(cmd, %{})

      assert SlowIO.should_delay?()
      {elapsed_us, :ok} = :timer.tc(&SlowIO.apply_delay/0)
      assert div(elapsed_us, 1000) >= 150, "I/O delay was not applied"

      {:ok, _} = SlowIO.restore(cmd, %{})
      refute SlowIO.should_delay?()
    end

    test "CertificateExpiry really flags TLS failure and restore clears it" do
      refute CertificateExpiry.should_fail?()

      cmd = %CertificateExpiry{failure_type: :expired, duration_ms: 5000}
      {:ok, _} = CertificateExpiry.inject(cmd, %{})

      assert CertificateExpiry.should_fail?()
      assert {:error, {:tls_alert, {:certificate_expired, _}}} = CertificateExpiry.get_ssl_error()

      {:ok, _} = CertificateExpiry.restore(cmd, %{})
      refute CertificateExpiry.should_fail?()
      assert CertificateExpiry.get_ssl_error() == nil
    end
  end
end
