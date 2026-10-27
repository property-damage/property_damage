defmodule PropertyDamage.ReplayWitnessTest do
  # One configuration in which every promise about reproducing a failure
  # holds at once: two in-process targets, the reference and a second target
  # both drawing at random, and a bug in the second target that only the
  # rewrite entry exposes. The run fails, shrinks and writes its replay
  # artifact; the report ends with the three paste-ready calls; replaying the
  # artifact reproduces the failure at the same root; `Expansion.for/5`
  # regenerates what the second target ran before shrinking; and the loader
  # refuses an unknown format and a function in the file.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @model F.Model
  @seed 2
  @max_commands 8

  defp run(targets, opts) do
    R.run(@model, targets, [seed: @seed, max_runs: 1, max_commands: @max_commands] ++ opts)
  end

  defp identity(report),
    do: {report.kind, Failure.name(report.failure_reason), report.variant.index}

  test "a failure shrinks, writes its artifact, replays, and regenerates its sequence" do
    targets = [F.target("ref"), F.target("second", :random, %{bug: :credit})]

    # The run fails, shrinks and writes the artifact.
    assert {:error, report} = run(targets, replay_dir: R.tmp_dir!())
    F.drain()

    assert report.shrink_iterations > 0
    path = R.replay_path!(report)
    term = R.term!(path)
    assert term == R.field(report, :replay)
    assert Enum.at(term.choices["second"], term.failure.root_index).entry == "Refund[1]"

    # The report ends with the three paste-ready calls, the replay call last.
    replay_call = R.replay_command(report)
    expansion_call = R.expansion_command(report)
    assert replay_call =~ "only: [replay: #{inspect(path)}]"

    assert R.last_lines(report, 5) == [
             R.printed(report, FailureReport.reproduction_command(report)),
             "# Regenerate the failing variant:",
             R.printed(report, expansion_call),
             "# Replay the shrunk failure:",
             R.printed(report, replay_call)
           ]

    # Replaying the artifact reproduces the failure at the same root.
    assert {:error, replayed} =
             PropertyDamage.run(
               model: @model,
               targets: targets,
               only: [replay: path],
               replay_dir: R.tmp_dir!(),
               compare: [converge_within: 1]
             )

    messages = F.drain()
    assert identity(replayed) == identity(report)
    assert replayed.failed_at_index == term.failure.root_index

    for executed <- F.segments(messages, "second") do
      assert F.without_suffix(executed) == R.concrete(term, "second")
    end

    # Expansion.for/5 regenerates what the unshrunk run of the same seed ran.
    {seed, run} = R.report_coordinates(report)

    assert {:ok, regenerated} =
             F.expansion_for(@model, seed, run, "second",
               targets: targets,
               max_commands: @max_commands
             )

    assert {:error, unshrunk} = run(targets, shrink: false, replay_dir: R.tmp_dir!())
    [executed | _] = F.segments(F.drain(), "second")

    executed_roots = Enum.take(regenerated.choices, unshrunk.failed_at_index + 1)

    assert F.without_suffix(executed) ==
             regenerated.prefix ++ Enum.flat_map(executed_roots, & &1.commands)

    assert List.starts_with?(regenerated.sequence, F.without_suffix(executed))

    # The loader refuses an unknown format and a function in the file.
    text = File.read!(path)
    version_zero = String.replace(text, "artifact, format 1", "artifact, format 0")
    assert {:error, _reason} = R.parse_artifact(version_zero)

    with_function = replace_in_term(text, "run: 1", "run: fn -> 1 end")
    assert {:error, reason} = R.parse_artifact(with_function)
    assert R.reason_text(reason) =~ "fn"
  end

  # `text` with the first occurrence of `from` outside a comment line
  # replaced by `to`.
  defp replace_in_term(text, from, to) do
    lines = String.split(text, "\n")

    at =
      Enum.find_index(lines, fn line ->
        not String.starts_with?(String.trim(line), "#") and String.contains?(line, from)
      end)

    lines
    |> List.update_at(at, &String.replace(&1, from, to, global: false))
    |> Enum.join("\n")
  end
end
