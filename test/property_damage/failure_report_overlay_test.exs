defmodule PropertyDamage.FailureReportOverlayTest do
  # A report reads the values its trace holds (seed, run number, model,
  # timestamp, command labels, failure reason, setup and teardown commands)
  # through accessors, a saved report keeps them, and one JSON document
  # describes a report whichever entry point builds it.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Persistence}
  alias PropertyDamage.FailureReport.{Bundle, Formatter}
  alias PropertyDamage.Test.ReportOverlayFixture, as: F

  @fields [
    :seed,
    :run_number,
    :model,
    :timestamp,
    :command_labels,
    :failure_reason,
    :setup_commands,
    :teardown_commands
  ]

  # Each of the eight values of a report: the struct field while the report
  # stores it, the accessor of the same name once the report derives it.
  defp values(report) do
    Map.new(@fields, fn field ->
      value =
        if Map.has_key?(report, field),
          do: Map.fetch!(report, field),
          else: apply(FailureReport, field, [report])

      {field, value}
    end)
  end

  defp through_accessors(report) do
    Map.new(@fields, fn field -> {field, apply(FailureReport, field, [report])} end)
  end

  # Changes the seed where the report holds it, in the trace and in the
  # struct alike.
  defp with_seed(report, seed) do
    report = %{report | trace: %{report.trace | seed: seed}}
    if Map.has_key?(report, :seed), do: %{report | seed: seed}, else: report
  end

  defp json(report, opts \\ []), do: report |> Formatter.format(:json, opts) |> normalize()
  defp exported(report), do: report |> Persistence.export_json() |> normalize()
  defp bundled(report, opts \\ []), do: report |> Bundle.build(opts) |> normalize()

  # A string or a map comes back as one decoded document with string keys.
  defp normalize(document) when is_binary(document), do: Jason.decode!(document)
  defp normalize(document), do: document |> Jason.encode!() |> Jason.decode!()

  describe "the eight values of a fixed failure" do
    test "hold the values the report held before it derived them" do
      values = values(F.failing_report())

      assert values.seed == 12_345
      assert values.run_number == 0
      assert values.model == F.Model
      assert %DateTime{} = values.timestamp
      assert values.command_labels == Map.new(0..49, &{&1, "send step"})
      assert %Failure{} = values.failure_reason
      assert Failure.kind(values.failure_reason) == :check_failed
      assert %Failure{type: %Failure.Check{name: :at_most_one}} = values.failure_reason
      assert values.setup_commands == [%F.Open{}]
      assert values.teardown_commands == [%F.Close{}]
    end
  end

  describe "a saved report" do
    @tag :known_defect
    @tag :tmp_dir
    test "loads with the eight values its trace holds, read through the accessors", %{
      tmp_dir: dir
    } do
      report = F.failing_report()
      {:ok, path} = Persistence.save(report, dir)
      assert {:ok, loaded} = Persistence.load(path)

      expected = through_accessors(report)

      assert expected.seed == 12_345
      assert expected.setup_commands == [%F.Open{}]
      assert expected.teardown_commands == [%F.Close{}]
      assert map_size(expected.command_labels) > 0
      assert %DateTime{} = expected.timestamp
      assert %Failure{} = expected.failure_reason

      assert through_accessors(loaded) == expected
      assert FailureReport.shrunk_sequence(loaded) == FailureReport.shrunk_sequence(report)
      assert loaded.state_at_failure == report.state_at_failure
      assert loaded.state_before_failure == report.state_before_failure
      assert loaded.state_at_failure != nil
    end
  end

  describe "the JSON document" do
    @tag :known_defect
    test "is the same from the formatter, the export and the bundle, and names the failure" do
      report = F.failing_report()
      document = json(report)

      assert exported(report) == document
      assert bundled(report) == document
      assert document["format"] == 2
      assert document["failure"]["kind"] == "check_failed"

      reason = inspect(document["failure"])
      assert reason =~ "at_most_one" or reason =~ "two sends"
    end

    @tag :known_defect
    test "differs when the report differs, so equality is not vacuous" do
      report = F.failing_report()
      changed = with_seed(report, 99)

      assert changed != report
      assert json(changed) != json(report)
      assert exported(changed) != exported(report)
      assert bundled(changed) != bundled(report)
      assert json(changed) == exported(changed)
      assert json(changed) == bundled(changed)
    end

    @tag :known_defect
    test "carries the source members only when sources are requested" do
      report = F.failing_report()
      source_members = ["modules", "ids", "missing_sources", "redactions"]

      plain = bundled(report)
      with_sources = bundled(report, sources: true)

      for member <- source_members do
        refute Map.has_key?(plain, member), "the plain document holds #{member}"
        assert Map.has_key?(with_sources, member), "the sourced document lacks #{member}"
      end

      assert Map.drop(with_sources, source_members) == plain
      assert json(report, sources: true) == with_sources
    end
  end
end
