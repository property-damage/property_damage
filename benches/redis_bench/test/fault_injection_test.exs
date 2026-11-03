defmodule RedisBench.FaultInjectionTest do
  @moduledoc """
  The Toxiproxy live oracle: real network faults in front of Redis.

  This is the foundation the nemesis audit rests on. Every test here proves a
  fault is REAL by a differential: the SUT's observable behavior (round-trip
  time, connectivity) changes measurably when the toxic is injected versus not.
  It also shows what PropertyDamage does with the SUT under those faults: a
  latency toxic does not break linearizability (Redis stays atomic), while a
  partition is reported honestly as a connection error, never as a false
  consistency violation.
  """
  use ExUnit.Case, async: false

  alias RedisBench.Toxiproxy

  @toxic_latency_ms 300

  # The toxic must add most of its configured latency. The slack below the full
  # amount absorbs timer granularity; a toxic that does nothing adds about 0.
  @min_added_ms 200

  # Allowed drift of the restored round-trip above the baseline. It covers
  # runner noise between measurements and stays well under the toxic latency,
  # so a toxic that was not removed (adding 300ms) still fails.
  @restore_margin_ms 150

  setup do
    :ok = Toxiproxy.ensure_clean_proxy()
    on_exit(fn -> Toxiproxy.ensure_clean_proxy() end)
    :ok
  end

  describe "the toxic is real (differential proof)" do
    test "a latency toxic measurably slows the round-trip" do
      baseline_ms = Toxiproxy.fastest_ping_ms()

      {:ok, _} = Toxiproxy.add_toxic("lag", "latency", %{latency: @toxic_latency_ms})
      laggy_ms = Toxiproxy.fastest_ping_ms()

      assert laggy_ms - baseline_ms >= @min_added_ms,
             "latency toxic should add at least #{@min_added_ms}ms " <>
               "(fastest ping #{laggy_ms}ms with it vs #{baseline_ms}ms without)"

      {:ok, _} = Toxiproxy.remove_toxic("lag")
      restored_ms = Toxiproxy.fastest_ping_ms()

      assert restored_ms - baseline_ms <= @restore_margin_ms,
             "removing the toxic should restore the baseline " <>
               "(fastest ping #{restored_ms}ms after vs #{baseline_ms}ms before)"
    end

    test "a disabled proxy partitions the connection" do
      assert {:ok, _ms} = Toxiproxy.probe_ping_ms()

      {:ok, _} = Toxiproxy.set_enabled(false)
      assert {:error, _reason} = Toxiproxy.probe_ping_ms(500)

      {:ok, _} = Toxiproxy.set_enabled(true)
      assert {:ok, _ms} = Toxiproxy.probe_ping_ms()
    end
  end

  describe "PropertyDamage under faults" do
    test "linearizability holds under a real latency toxic" do
      {:ok, _} = Toxiproxy.add_toxic("lag", "latency", %{latency: 15})

      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: RedisBench.Model,
                 targets: [RedisBench.ProxyAdapter],
                 max_commands: 12,
                 max_runs: 10,
                 verbose: false
               )
    end

    test "a partition is reported as a connection error, not a consistency violation" do
      {:ok, _} = Toxiproxy.set_enabled(false)

      assert {:error, report} =
               PropertyDamage.run(
                 model: RedisBench.Model,
                 targets: [RedisBench.ProxyAdapter],
                 max_commands: 12,
                 max_runs: 5,
                 seed: 1,
                 verbose: false
               )

      # The failure must be the honest adapter/connection error, never an
      # check or linearization verdict (which would be a false positive:
      # the SUT never gave an inconsistent answer, it was unreachable).
      refute redis_unavailable_misreported_as_inconsistency?(report)
      assert redis_unavailable?(report)
    end
  end

  defp redis_unavailable?(report) do
    report
    |> inspect(limit: :infinity)
    |> String.contains?("redis_unavailable")
  end

  defp redis_unavailable_misreported_as_inconsistency?(report) do
    rendered = inspect(report, limit: :infinity)

    String.contains?(rendered, "no_linearization") or
      String.contains?(rendered, "check_failed")
  end
end
