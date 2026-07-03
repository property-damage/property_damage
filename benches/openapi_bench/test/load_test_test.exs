defmodule OpenapiBench.LoadTestTest do
  @moduledoc """
  Exercises `PropertyDamage.LoadTest` (WIP-tier) against the in-process KV HTTP
  SUT. This is the promotion vehicle for the LoadTest feature: it drives real
  concurrent load through the framework's worker pool and proves

    1. the report carries real, well-typed metrics (throughput, latency
       percentiles, error counts, per-command breakdown, worker-pool stats), and
    2. invariant checking stays active under load — with `assertion_mode:
       :record` a faithful SUT yields zero assertion failures (non-vacuity),
       while the seeded dropped-write bug is caught many times over under load.

  The second pair is the RED/GREEN evidence: the same load configuration produces
  0 failures against the faithful SUT and thousands against the buggy one, so the
  detection is real and not a false positive.
  """
  use ExUnit.Case, async: false

  alias OpenapiBench.Generated.Commands.{GetValue, PutValue}
  alias OpenapiBench.Server

  @moduletag timeout: 120_000

  # ~150 sessions/second for 2 seconds. Enough overlap that many workers run
  # concurrently (the point of a load test), while staying a few seconds long.
  @load [
    model: OpenapiBench.LoadModel,
    adapter: OpenapiBench.LoadAdapter,
    arrival_rate: 150,
    duration: {2, :seconds},
    assertion_mode: :record
  ]

  test "reports real throughput/latency/worker metrics and stays invariant-clean under load" do
    Server.reset(false)

    assert {:ok, report} =
             PropertyDamage.LoadTest.run(
               @load ++ [adapter_config: %{base_url: Server.base_url()}]
             )

    m = report.metrics
    p = report.pool_stats

    # Throughput is real.
    assert m.total_requests > 0
    assert is_float(m.requests_per_second) and m.requests_per_second > 0.0
    assert m.arrivals_spawned > 0
    assert m.arrivals_completed > 0

    # Latency percentiles are real, ordered floats.
    for field <- [
          :latency_min,
          :latency_p50,
          :latency_p95,
          :latency_p99,
          :latency_max,
          :latency_mean
        ] do
      assert is_float(Map.fetch!(m, field)) and Map.fetch!(m, field) >= 0.0
    end

    assert m.latency_max > 0.0
    assert m.latency_p50 <= m.latency_p95
    assert m.latency_p95 <= m.latency_p99

    # Error counts are real fields (a faithful in-process SUT produces none).
    assert is_integer(m.total_errors) and m.total_errors >= 0
    assert is_map(m.errors_by_type)
    assert is_float(m.error_rate)

    # Per-command breakdown covers both commands with real counts.
    assert Map.has_key?(m.by_command, PutValue)
    assert Map.has_key?(m.by_command, GetValue)
    assert m.by_command[PutValue].count > 0
    assert m.by_command[GetValue].count > 0

    # Multiple workers actually ran concurrently.
    assert p.total_created >= 2
    assert p.peak_in_use >= 2

    # Invariant checking was active (assertion_mode: :record) yet the faithful
    # SUT produced zero violations: the check is live but non-vacuous.
    assert m.assertion_failures == 0
    assert m.failures_by_exception == %{}
  end

  test "invariant checking catches the seeded dropped-write bug under load" do
    Server.reset(true)

    assert {:ok, report} =
             PropertyDamage.LoadTest.run(
               @load ++ [adapter_config: %{base_url: Server.base_url()}]
             )

    m = report.metrics

    # Under the same load config that was clean above, the dropped-write bug is
    # caught by the read-your-write invariant many times over. A worker recorded
    # the failures, proving assertions run under load.
    assert m.total_requests > 0
    assert m.assertion_failures > 0
    assert map_size(m.failures_by_exception) > 0
    assert Map.has_key?(m.failures_by_exception, PropertyDamage.AssertionFailed)

    # Leave the shared SUT clean for subsequent tests.
    Server.reset(false)
  end
end
