defmodule PropertyDamage.ReportFooterTest do
  # A failure report records the campaign run it failed in, where its replay
  # artifact is, and the artifact's term. Its printed form ends with three
  # paste-ready calls: the seed reproduction, the call that regenerates the
  # failing target's sequence, and, last, the call that replays the artifact.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Sequence}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @model F.Model
  @seed 2
  @max_commands 8

  # At seed 3 with 4 commands, "second" first runs Refund[1] in run 3, so
  # the planted bug fails run 3 of a `max_runs: 5` campaign (a bounded search
  # over 1..300; fixture smoke test below).
  @run3_seed 3
  @run3_max_commands 4

  defp replay_command(report), do: R.replay_command(report)

  defp expansion_command(report), do: R.expansion_command(report)

  defp bugged(name, mode \\ :random), do: F.target(name, mode, %{bug: :credit})

  defp failing(targets, opts) do
    opts = Keyword.merge([seed: @seed, max_runs: 1, replay_dir: R.tmp_dir!()], opts)
    assert {:error, %FailureReport{} = report} = R.run(@model, targets, opts)
    F.drain()
    report
  end

  defp two, do: [F.target("ref"), bugged("second")]

  describe "report fields" do
    test "run is the campaign run the failure happened in; replay_path and replay are set" do
      report = failing(two(), seed: @run3_seed, max_runs: 5, max_commands: @run3_max_commands)

      assert R.report_run(report) == 3
      assert report.seed == R.run_seed_for(@run3_seed, 3)

      path = R.replay_path!(report)
      assert %{seed: seed, run: 1} = R.field(report, :replay)
      assert {seed, 1} == R.report_coordinates(report)
      assert R.term!(path) == R.field(report, :replay)
    end
  end

  describe "the paste-ready calls" do
    test "replay_command/1 replays the artifact on the report's targets" do
      report = failing(two(), max_commands: @max_commands)
      path = R.replay_path!(report)

      # The run's convergence bound (`converge_within: 1`, see `R.run/3`) is
      # not the default, so the call names it.
      assert replay_command(report) ==
               "PropertyDamage.run(model: PropertyDamage.Test.ExpansionFor.Model, " <>
                 "targets: #{FailureReport.targets_source(report)}, " <>
                 "compare: [converge_within: 1], " <>
                 "only: [replay: #{inspect(path)}])"
    end

    test "expansion_command/1 for a :random failing target with the default options" do
      report = failing(two(), [])
      {seed, run} = R.report_coordinates(report)

      assert expansion_command(report) ==
               "PropertyDamage.Expansion.for(PropertyDamage.Test.ExpansionFor.Model, " <>
                 "#{seed}, #{run}, \"second\")"
    end

    test "expansion_command/1 names max_commands: when the run did not use the default" do
      report = failing(two(), max_commands: @max_commands)
      {seed, run} = R.report_coordinates(report)

      assert expansion_command(report) ==
               "PropertyDamage.Expansion.for(PropertyDamage.Test.ExpansionFor.Model, " <>
                 "#{seed}, #{run}, \"second\", max_commands: 8)"
    end

    test "expansion_command/1 names the targets for a :reference failing target" do
      report = failing([F.target("ref"), F.target("second"), bugged("third", :reference)], [])
      assert report.variant.name == "third"
      {seed, run} = R.report_coordinates(report)

      assert expansion_command(report) ==
               "PropertyDamage.Expansion.for(PropertyDamage.Test.ExpansionFor.Model, " <>
                 "#{seed}, #{run}, \"third\", targets: #{FailureReport.targets_source(report)})"
    end

    test "the targets a :reference failing target's call names keep its mode" do
      report = failing([F.target("ref"), F.target("second"), bugged("third", :reference)], [])
      assert expansion_command(report) =~ "expansion: :reference"
    end

    test "reproduction_command/1 is the seed reproduction it was" do
      report = failing(two(), max_commands: @max_commands)

      assert FailureReport.reproduction_command(report) ==
               "PropertyDamage.run(model: PropertyDamage.Test.ExpansionFor.Model, " <>
                 "targets: #{FailureReport.targets_source(report)}, " <>
                 "compare: [converge_within: 1], max_commands: 8, " <>
                 "seed: #{report.seed}, max_runs: 1)"
    end
  end

  describe "the printed footer" do
    test "ends with the reproduction, the Expansion.for call, then the replay call last" do
      report = failing(two(), max_commands: @max_commands)

      assert R.last_lines(report, 5) == [
               FailureReport.reproduction_command(report),
               "Regenerate the failing variant:",
               expansion_command(report),
               "Replay the shrunk failure:",
               replay_command(report)
             ]
    end

    test "with replay_dir: false names the option where the replay call would be" do
      report = failing(two(), max_commands: @max_commands, replay_dir: false)

      assert [regenerate, _call, label, last] = R.last_lines(report, 4)
      assert regenerate == "Regenerate the failing variant:"
      assert label == "Replay the shrunk failure:"
      assert last =~ "replay_dir: false"
      refute last =~ "only: [replay:"
    end

    test "prints an identity reached by shrinking as such beside the failing root" do
      refund = %F.Refund{amount: 10}
      sequence = Sequence.linear([refund])

      credits = [
        %F.Credit{amount: 5, part: 0, memo: 1},
        %F.Credit{amount: 5, part: 1, memo: 2}
      ]

      choice = fn name, entry, index, commands ->
        %{
          root: 0,
          root_id: 0,
          module: F.Refund,
          entry: entry,
          index: index,
          commands: commands,
          leaves?: index == 1,
          seed_key: {1, name, 0},
          aliases: %{}
        }
      end

      expansion = %{
        variants: %{
          "ref" => %{choices: [choice.("ref", :identity, nil, [refund])], registry: nil},
          "second" => %{choices: [choice.("second", "Refund[1]", 1, credits)], registry: nil}
        },
        warnings: []
      }

      report =
        FailureReport.new(
          seed: 1,
          run_number: 0,
          failed_at_index: 0,
          failure_reason: Failure.check_failed(:refund_total, "totals differ"),
          original_sequence: sequence,
          shrunk_sequence: sequence,
          model: @model,
          targets: [F.target("ref"), F.target("second")],
          variant: %{index: 1, name: "second"},
          expansion: expansion
        )

      lines = report |> R.text() |> String.split("\n") |> Enum.map(&String.trim/1)

      assert "ref (reference): Refund (identity, by shrinking)" in lines
      assert "second: Refund[1] = [Credit, Credit]" in lines
    end
  end

  describe "fixture smoke" do
    test "at the run-3 seed, \"second\" first runs the rewrite in run 3" do
      {:ok, targets} = PropertyDamage.Options.validate_targets(two())

      ran_rewrite =
        for run <- 1..3 do
          sequence = F.generated(@model, @run3_seed, run, @run3_max_commands)
          seed = R.run_seed_for(@run3_seed, run)
          expansion = PropertyDamage.Expansion.expand(@model, sequence, targets, seed)
          "Refund[1]" in Enum.map(expansion.variants["second"].choices, & &1.entry)
        end

      assert ran_rewrite == [false, false, true]
    end

    test "with three targets the :reference target is the one that fails" do
      assert {:error, report} =
               R.smoke_run(
                 model: @model,
                 targets: [F.target("ref"), F.target("second"), bugged("third", :reference)],
                 seed: @seed,
                 max_runs: 1,
                 compare: [converge_within: 1]
               )

      F.drain()
      assert report.variant == %{index: 2, name: "third"}
    end
  end
end
