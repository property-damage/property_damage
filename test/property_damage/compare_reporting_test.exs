defmodule PropertyDamage.CompareReportingTest do
  # A divergence and a failure to converge are named by a `{projection,
  # function}` key. Every place that renders, exports or stores a failure's
  # name handles that key, and shows it as `Projection.function`.
  use ExUnit.Case, async: true

  alias PropertyDamage.{
    Analysis,
    Error,
    Failure,
    FailureReport,
    Persistence,
    SeedLibrary,
    Sequence,
    Shrinker
  }

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.Compare.{Counter, Pay, PayAdapter}

  @key {Counter, :totals}
  @label "#{inspect(Counter)}.totals"

  defp diverged do
    Failure.diverged(%{
      key: @key,
      root: 0,
      command: %Pay{n: 0, amount: 1},
      reference_value: %{settled: 1},
      variant_value: %{settled: 2},
      mismatch: %PropertyDamage.ComparisonMismatch{left: %{settled: 1}, right: %{settled: 2}}
    })
  end

  defp did_not_converge do
    Failure.did_not_converge(%{
      key: @key,
      root: 0,
      command: %Pay{n: 0, amount: 1},
      reason: :unsettled,
      waited_ms: 120,
      within_ms: 100
    })
  end

  defp report(reason) do
    FailureReport.new(
      seed: 1,
      run_number: 0,
      original_sequence: Sequence.linear([%Pay{n: 0, amount: 1}]),
      failed_at_index: 0,
      failure_reason: reason,
      variant: %{index: 1, name: "b"},
      targets: [{PayAdapter, [name: "a"]}, {PayAdapter, [name: "b"]}],
      compare: [converge_within: 100],
      compare_counts: %{@key => %{compared_at: 1, waited_at: 1, waited_ms: 120}}
    )
  end

  test "PropertyDamage.Error names the observation of a divergence and of a failure to converge" do
    assert Error.format(diverged()) =~ "Divergence of #{@label} at root 0"

    assert Error.format(did_not_converge()) =~
             "#{@label} did not converge within 100 ms at root 0"

    assert Error.format(did_not_converge()) =~ "Waited: 120 ms"
  end

  test "every report format renders a key-named failure" do
    for reason <- [diverged(), did_not_converge()] do
      report = report(reason)

      assert Formatter.format(report, :markdown) =~ "Did Not Converge" or
               Formatter.format(report, :markdown) =~ "Divergence"

      assert Jason.decode!(Formatter.format(report, :json))["failure"]["check_name"] == @label
      assert is_binary(Formatter.format(report, :compact))
    end
  end

  test "the failure analysis and a generated test name the observation" do
    report = report(diverged())

    assert Analysis.explain(report) |> Analysis.format_explanation() =~ @label
    assert Analysis.generate_test(report) =~ @label
  end

  test "the JSON export carries the run's bound and the compare counts by label" do
    exported = report(diverged()) |> Persistence.export_json() |> Jason.decode!()

    assert exported["compare"] == %{"converge_within" => 100}
    assert exported["compare_counts"][@label]["waited_ms"] == 120
    assert exported["check_name"] == @label
  end

  test "a failure to converge is rebuilt from its signature" do
    signature = Shrinker.failure_signature(did_not_converge(), 1)
    {kind, name, 1} = signature

    assert Shrinker.failure_signature(Failure.from_signature(kind, name), 1) == signature
  end

  test "a seed library stores a key-named failure as the observation's label" do
    path =
      Path.join(System.tmp_dir!(), "pd_compare_seeds_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    {:ok, library} = SeedLibrary.add(SeedLibrary.new(), report(diverged()))
    assert :ok = SeedLibrary.save(library, path)
    assert {:ok, loaded} = SeedLibrary.load(path)
    assert [%{check_name: check_name}] = loaded.entries
    assert Atom.to_string(check_name) == @label
  end
end
