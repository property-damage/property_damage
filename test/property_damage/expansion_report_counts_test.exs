defmodule PropertyDamage.ExpansionReportCountsTest do
  # A failure report's `expansion_counts` count, for the run the report
  # describes, the choices at the roots that run executed: every root up to and
  # including the failing root. The `expansions` field stops at the same root,
  # so the two fields describe the same roots. A listed root after the failing
  # root is not counted.
  use ExUnit.Case, async: false

  alias PropertyDamage.{FailureReport, Sequence}
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Noise, Pay, Refund}

  @names ["alpha", "beta", "gamma"]

  defp model do
    module = ExpansionReportCounts.Model

    if Code.ensure_loaded?(module) do
      module
    else
      X.define_model!(module,
        commands: [Noise, Refund, Pay],
        expansions: [{Refund, &X.refund_two/2}, {Pay, &X.none/2}]
      )
    end
  end

  defp run(seed, shrink) do
    PropertyDamage.run(
      model: model(),
      targets: [
        X.target("alpha", nil),
        X.target("beta", nil, %{bug: :credit}),
        X.target("gamma", nil, %{}, expansion: :reference)
      ],
      compare: [converge_within: 30],
      seed: seed,
      max_runs: 1,
      max_commands: 12,
      shrink: shrink,
      validate: false
    )
  end

  defp listed?(root), do: match?(%Refund{}, root) or match?(%Pay{}, root)

  # Listed roots in `sequence` up to and including root `failed_at`.
  defp listed_through(sequence, failed_at) do
    sequence |> Sequence.to_list() |> Enum.take(failed_at + 1) |> Enum.count(&listed?/1)
  end

  defp counted(report, name) do
    report
    |> Map.fetch!(:expansion_counts)
    |> Map.fetch!(name)
    |> Enum.flat_map(fn {_root_module, by_entry} -> Map.values(by_entry) end)
    |> Enum.sum()
  end

  test "the counts stop at the failing root, for the found run and for the shrunk reproduction" do
    {seed, report} =
      Enum.find_value(1..60, fn seed ->
        with {:error, %FailureReport{} = report} <- run(seed, false),
             roots = Sequence.to_list(report.original_sequence),
             true <- roots |> Enum.drop(report.failed_at_index + 1) |> Enum.any?(&listed?/1) do
          {seed, report}
        else
          _ -> nil
        end
      end) || flunk("no seed in 1..60 fails before a listed root")

    expected = listed_through(report.original_sequence, report.failed_at_index)
    assert expected > 0

    for name <- @names do
      assert counted(report, name) == expected, "#{name} counts #{counted(report, name)}"

      assert length(Map.fetch!(report, :expansions) |> Map.fetch!(name)) ==
               report.failed_at_index + 1
    end

    assert {:error, %FailureReport{} = shrunk} = run(seed, true)

    shrunk_expected =
      listed_through(FailureReport.shrunk_sequence(shrunk), shrunk.failed_at_index)

    for name <- @names do
      assert counted(shrunk, name) == shrunk_expected
    end
  end
end
