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

  setup do
    :ok = Toxiproxy.ensure_clean_proxy()
    on_exit(fn -> Toxiproxy.ensure_clean_proxy() end)
    :ok
  end

  describe "the toxic is real (differential proof)" do
    test "a latency toxic measurably slows the round-trip" do
      {:ok, clean_ms} = Toxiproxy.probe_ping_ms()
      assert clean_ms < 100, "baseline ping should be fast, was #{clean_ms}ms"

      {:ok, _} = Toxiproxy.add_toxic("lag", "latency", %{latency: 300})

      {:ok, laggy_ms} = Toxiproxy.probe_ping_ms()

      assert laggy_ms >= 250,
             "latency toxic should add ~300ms (was #{laggy_ms}ms vs clean #{clean_ms}ms)"

      {:ok, _} = Toxiproxy.remove_toxic("lag")

      {:ok, restored_ms} = Toxiproxy.probe_ping_ms()
      assert restored_ms < 100, "removing the toxic should restore speed, was #{restored_ms}ms"
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
                 adapter: RedisBench.ProxyAdapter,
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
                 adapter: RedisBench.ProxyAdapter,
                 max_commands: 12,
                 max_runs: 5,
                 seed: 1,
                 verbose: false
               )

      # The failure must be the honest adapter/connection error, never an
      # assertion or linearization verdict (which would be a false positive:
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
      String.contains?(rendered, "assertion_failed")
  end
end
