defmodule CachexBench.CoverageTest do
  @moduledoc """
  Exercises PropertyDamage's coverage metrics (feature 14) against the cache
  bench: command/transition coverage thresholds and DR-026 anti-vacuity
  (assertion) coverage. These are the assertions a CI job would gate on to catch
  a suite that has silently stopped exercising part of the model.
  """
  use ExUnit.Case, async: false

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, PutKey}
  alias PropertyDamage.Coverage

  @moduletag timeout: 120_000

  test "the suite meets command/transition/assertion coverage thresholds" do
    assert {:ok, stats} =
             PropertyDamage.run(
               model: CachexBench.Model,
               adapter: CachexBench.Adapter,
               coverage: true,
               max_commands: 30,
               max_runs: 150,
               seed: 1,
               verbose: false
             )

    coverage = stats.coverage

    # All four commands are exercised, and enough transitions/commands to make
    # the run non-vacuous. Thresholds are conservative to stay stable across
    # seeds while still failing if a command stops being generated.
    assert Coverage.command_coverage(coverage) == 100.0
    assert Coverage.untested_commands(coverage) == []

    assert Coverage.meets_threshold?(coverage,
             command: 100,
             transition: 60,
             min_commands: 500,
             assertion_coverage: 100
           )

    # Every command has a non-trivial share of the executions.
    for cmd <- [PutKey, GetKey, DelKey, ClearCache] do
      assert Map.get(coverage.command_counts, cmd, 0) > 0
    end

    # DR-026 anti-vacuity, tracker rollup: the one declared invariant is
    # exercised, none left uncovered.
    assert Coverage.assertion_coverage(coverage) == 100.0
    assert Coverage.uncovered_invariants(coverage) == []
  end

  test "the read-consistency invariant is exercised (DR-026 anti-vacuity)" do
    result =
      PropertyDamage.run(
        model: CachexBench.Model,
        adapter: CachexBench.Adapter,
        max_commands: 30,
        max_runs: 150,
        seed: 1,
        verbose: false
      )

    assert {:ok, _stats} = result

    # PropertyDamage.assertion_coverage/2 reports per-invariant firing on the
    # aggregate run result (joins assertion_fires against the model catalog).
    entries = PropertyDamage.assertion_coverage(result, CachexBench.Model)
    assert [%{id: :read_consistent, covered?: true, fire_count: fires}] = entries
    assert fires > 0
  end
end
