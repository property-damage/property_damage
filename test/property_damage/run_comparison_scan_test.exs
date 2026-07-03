defmodule PropertyDamage.RunComparison.ScanTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.RunComparison
  alias PropertyDamage.RunComparison.Verdict
  alias PropertyDamage.Test.Flake.{Adapter, Model}

  # Concrete seeds classified by the banding adapter (see flakiness_support.ex):
  # the generated `amount` is a pure function of the seed, so these are stable.
  @flaky_seed 1
  @stable_seed 0
  @broken_seed 4

  setup do
    # A fresh atomic counter per test isolates the flaky band's alternation.
    ref = :counters.new(1, [:atomics])
    {:ok, config: %{counter: ref}}
  end

  defp scan(seeds, runs, config) do
    RunComparison.scan(
      seeds: seeds,
      runs: runs,
      capture: [model: Model, adapter: Adapter, adapter_config: config]
    )
  end

  describe "scan/1" do
    test "returns a per-seed verdict map keyed by the scanned seeds", %{config: config} do
      verdicts = scan([@flaky_seed, @stable_seed, @broken_seed], 4, config)

      assert Enum.sort(Map.keys(verdicts)) ==
               Enum.sort([@flaky_seed, @stable_seed, @broken_seed])

      assert %Verdict{seed: @flaky_seed, runs: 4} = verdicts[@flaky_seed]
    end

    test "flags an intermittent seed flaky with a mixed outcome partition", %{config: config} do
      v = scan([@flaky_seed], 4, config)[@flaky_seed]

      assert v.flaky?
      assert v.partition.passing > 0
      assert v.partition.failing > 0
      assert v.partition.passing + v.partition.failing == 4
    end

    test "retains the comparison for a flaky seed so divergence is one field away",
         %{config: config} do
      v = scan([@flaky_seed], 4, config)[@flaky_seed]

      assert %RunComparison{comparable?: true} = v.comparison
    end

    test "a consistently passing seed is not flaky and its comparison is dropped",
         %{config: config} do
      v = scan([@stable_seed], 4, config)[@stable_seed]

      refute v.flaky?
      assert v.partition.passing == 4
      assert v.partition.failing == 0
      assert v.comparison == nil
    end

    test "a consistently failing seed is not flaky", %{config: config} do
      v = scan([@broken_seed], 4, config)[@broken_seed]

      refute v.flaky?
      assert v.partition.failing == 4
      assert v.partition.passing == 0
      assert v.comparison == nil
    end

    test "one scan differentiates flaky, stable and broken seeds", %{config: config} do
      verdicts = scan([@flaky_seed, @stable_seed, @broken_seed], 4, config)

      assert verdicts[@flaky_seed].flaky?
      refute verdicts[@stable_seed].flaky?
      refute verdicts[@broken_seed].flaky?
    end

    test "requires :seeds and :capture and defaults :runs", %{config: config} do
      assert_raise NimbleOptions.ValidationError, fn ->
        RunComparison.scan(capture: [model: Model, adapter: Adapter, adapter_config: config])
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        RunComparison.scan(seeds: [@stable_seed])
      end
    end
  end

  describe "outcome_summary/1" do
    test "summarizes a comparison by outcome without digging into groups",
         %{config: config} do
      {_traces, comparison} =
        RunComparison.investigate(
          runs: 4,
          capture: [model: Model, adapter: Adapter, seed: @flaky_seed, adapter_config: config]
        )

      summary = RunComparison.outcome_summary(comparison)

      assert summary.passing + summary.failing == 4
      assert summary.passing > 0
      assert summary.failing > 0
      assert is_list(summary.failure_signatures)
    end
  end
end
