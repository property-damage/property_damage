defmodule PropertyDamage.ShrunkReportCountsTest do
  # A shrunk report describes the reproduction of its shrunk sequence, so its
  # `compare_counts` are the reproduction's, from `run/1` and from
  # `shrink_further/2`. Its `check_fires` count the runs before the failing
  # one plus the reproduction, in place of the failing run, from both.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, FailureReport, Sequence}
  alias PropertyDamage.Test.{FailingModel, SimpleAdapter}
  alias PropertyDamage.Test.ShrinkAxis, as: A

  # At seed 1 the run fails at root 5 and shrinks to one root.
  defp parts_run(opts) do
    PropertyDamage.run(
      [
        model: A.PartsModel,
        targets: [A.target("ref"), A.target("second", :random, %{bug: :part1})],
        compare: [converge_within: 1],
        max_runs: 1,
        max_commands: 8,
        seed: 1,
        replay_dir: false
      ] ++ opts
    )
  end

  # At seed 1 the run fails at root 6; the shrunk sequence fails earlier.
  defp items_run(opts) do
    PropertyDamage.run(
      [
        model: FailingModel,
        targets: [{SimpleAdapter, name: "a"}],
        max_runs: 1,
        max_commands: 10,
        seed: 1,
        replay_dir: false
      ] ++ opts
    )
  end

  # The `@compare every: 1` observation is compared after every root run.
  defp compared_at(report), do: report.compare_counts[{A.Sum, :sum}].compared_at

  # The check firings of the shrunk sequence, run once on its own.
  defp fires_of(report) do
    {:ok, result} =
      Executor.run(FailureReport.shrunk_sequence(report), FailingModel, SimpleAdapter, [])

    for {{:fired, projection, name}, count} <- result.check_counters,
        into: %{},
        do: {{projection, name}, count}
  end

  defp roots(report), do: report |> FailureReport.shrunk_sequence() |> Sequence.to_list()

  test "run/1 reports the reproduction's compare counts" do
    assert {:error, found} = parts_run(shrink: false)
    assert compared_at(found) == found.failed_at_index + 1

    assert {:error, shrunk} = parts_run([])
    assert shrunk.failed_at_index < found.failed_at_index
    assert compared_at(shrunk) == shrunk.failed_at_index + 1
  end

  test "shrink_further/2 reports the reproduction's compare counts" do
    assert {:error, found} = parts_run(shrink: false)
    assert {:ok, further} = PropertyDamage.shrink_further(found)

    assert length(roots(further)) < length(roots(found))
    assert compared_at(further) == further.failed_at_index + 1
  end

  test "run/1 reports the reproduction's check firings" do
    assert {:error, found} = items_run(shrink: false)
    assert {:error, shrunk} = items_run([])

    assert shrunk.failed_at_index < found.failed_at_index
    assert shrunk.check_fires == fires_of(shrunk)
    assert shrunk.run_check_fires == fires_of(shrunk)
    assert found.check_fires == fires_of(found)
    assert found.run_check_fires == fires_of(found)
  end

  test "shrink_further/2 replaces the reproduction's check firings with its own" do
    assert {:error, found} = items_run(shrink: false)
    [{key, _count}] = Map.to_list(found.check_fires)

    # Firings of runs before the failing one stay; 100 stands for them.
    earlier = %{found | check_fires: Map.update!(found.check_fires, key, &(&1 + 100))}

    assert {:ok, further} = PropertyDamage.shrink_further(earlier)
    assert length(roots(further)) < length(roots(found))
    assert further.check_fires == Map.update!(fires_of(further), key, &(&1 + 100))
  end
end
