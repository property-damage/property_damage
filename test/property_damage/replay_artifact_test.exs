defmodule PropertyDamage.ReplayArtifactTest do
  # A failing run writes a replay artifact: one Elixir source file holding one
  # literal term (the setup commands, the shrunk roots and, per target, the
  # concrete commands it ran at each root), after a header comment and
  # comment lines a reader can follow. The same failure writes the same bytes.
  # A command field holding a value no file can hold (a function, a pid, a
  # reference, a port) refuses the artifact, naming where the value sits,
  # and leaves the run's result as it was.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Sequence}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @model F.Model

  # At seed 2 the run fails in run 1: "second" ran Refund[1] at root 1 (see
  # the fixture smoke tests in expansion_for_test.exs).
  @seed 2
  @max_commands 8

  # At seed 4 with 6 commands, ExternalModel fails with a Refund whose leaves
  # carry the account placeholder (fixture smoke test below).
  @external_seed 4

  @header "# PropertyDamage replay artifact, format 1"

  @term_keys [:choices, :failure, :format, :model, :prefix, :roots, :run, :seed, :targets]

  defp targets, do: [F.target("ref"), F.target("second", :random, %{bug: :credit})]

  defp failing(opts \\ []) do
    opts =
      Keyword.merge(
        [seed: @seed, max_runs: 1, max_commands: @max_commands, replay_dir: R.tmp_dir!()],
        opts
      )

    assert {:error, %FailureReport{} = report} = R.run(@model, targets(), opts)
    F.drain()
    report
  end

  defp external_failing(dir) do
    targets = [R.target("ref"), R.target("second", :random, %{bug: true})]

    assert {:error, report} =
             R.run(R.ExternalModel, targets,
               seed: @external_seed,
               max_runs: 1,
               max_commands: 6,
               replay_dir: dir
             )

    F.drain()
    report
  end

  # The term the artifact of `report` must hold, from the report's own record
  # of the run: its setup commands, its roots and every target's choices.
  defp expected_term(report, model) do
    choices = report.trace.expansion
    ids = Enum.map(choices["ref"], & &1.root_id)

    %{
      format: 1,
      model: model,
      seed: report.seed,
      run: 1,
      targets: [%{name: "ref", expansion: :random}, %{name: "second", expansion: :random}],
      failure: %{
        kind: report.kind,
        name: Failure.name(report.failure_reason),
        variant_index: report.variant.index,
        root_index: report.failed_at_index
      },
      prefix: report.setup_commands,
      roots: Enum.zip_with(ids, R.roots(report), &%{root_id: &1, command: &2}),
      choices:
        Map.new(choices, fn {name, list} -> {name, Enum.map(list, &R.recorded_choice/1)} end)
    }
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n") |> Enum.map(&String.trim/1)

  # The comment naming what a target ran at root `index`.
  defp entry_comment(index, %{entry: entry, commands: commands}, root) do
    leaves = Enum.map_join(commands, ", ", &R.short(&1.__struct__))
    name = R.short(root.__struct__)

    case entry do
      nil -> "# root #{index}: #{name} (not expanded)"
      :identity -> "# root #{index}: #{name} (identity, by shrinking)"
      :forced -> "# root #{index}: #{name} (identity, forced)"
      key -> "# root #{index}: #{key} = [#{leaves}]"
    end
  end

  describe "the file a failing run writes" do
    test "is named after the model and the seed, in a replay_dir: created on demand" do
      dir = R.missing_dir!()
      report = failing(replay_dir: dir)

      path = Path.join(dir, "Model_seed#{report.seed}.replay.exs")
      assert R.artifact_name(report) == "Model_seed#{report.seed}.replay.exs"
      assert R.field(report, :replay_path) == path
      assert R.files(dir) == [R.artifact_name(report)]
    end

    test "holds the term the report's replay field holds" do
      report = failing()
      path = R.replay_path!(report)

      assert {:ok, term} = R.read_artifact(path)
      assert R.field(report, :replay) == term
    end

    test "starts with the header, then names the model, the seed, the run and the targets" do
      report = failing()
      [first | _] = lines = lines(R.replay_path!(report))

      assert first == @header
      assert "# model: PropertyDamage.Test.ExpansionFor.Model" in lines
      assert "# seed: #{report.seed}" in lines
      assert Enum.any?(lines, &String.starts_with?(&1, "# run: 1"))
      assert ~s|# target "ref" (reference), expansion: :random| in lines
      assert ~s|# target "second", expansion: :random| in lines
    end

    test "names each root, and what each target ran there, in comments inside the term" do
      report = failing()
      path = R.replay_path!(report)
      term = R.term!(path)
      lines = lines(path)
      term_start = Enum.find_index(lines, &(&1 != "" and not String.starts_with?(&1, "#")))

      for {%{command: root}, index} <- Enum.with_index(term.roots) do
        root_comment = "# root #{index}: #{R.short(root.__struct__)}"
        assert at = Enum.find_index(lines, &(&1 == root_comment)), "no line #{root_comment}"
        assert at > term_start

        comments =
          for name <- ["ref", "second"],
              do: entry_comment(index, Enum.at(term.choices[name], index), root)

        for comment <- Enum.uniq(comments) do
          assert Enum.count(lines, &(&1 == comment)) == Enum.count(comments, &(&1 == comment)),
                 "expected one line #{comment} per target that ran it"
        end
      end

      # The failing root's entries: "second" ran the rewrite there.
      assert Enum.at(term.choices["second"], report.failed_at_index).entry == "Refund[1]"
    end
  end

  describe "the term" do
    test "has exactly the documented keys and describes the shrunk failure" do
      report = failing()
      term = R.term!(R.replay_path!(report))

      assert term |> Map.keys() |> Enum.sort() == @term_keys
      assert term == expected_term(report, @model)

      assert term.failure.kind == :diverged
      assert term.failure.variant_index == 1
      assert [%F.Fund{}] = term.prefix
    end

    test "records the setup commands but never a teardown command" do
      report = failing()
      path = R.replay_path!(report)

      assert report.teardown_commands != []
      refute File.read!(path) =~ "ExpansionFor.Close"
      assert R.term!(path).prefix == report.setup_commands
    end

    test "prints its top-level keys and the failure's keys in sorted order" do
      report = failing()

      code =
        report
        |> R.replay_path!()
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
        |> Enum.join("\n")

      offsets =
        for key <- @term_keys do
          assert {at, _} = :binary.match(code, "#{key}: "), "no key #{key}: in the term"
          at
        end

      assert offsets == Enum.sort(offsets)

      failure_offsets =
        for key <- [:kind, :name, :root_index, :variant_index] do
          {at, _} = :binary.match(code, "#{key}: ")
          at
        end

      assert failure_offsets == Enum.sort(failure_offsets)
    end

    test "holds placeholders as struct literals that read back equal" do
      report = external_failing(R.tmp_dir!())
      path = R.replay_path!(report)
      term = R.term!(path)

      assert File.read!(path) =~ "%PropertyDamage.Placeholder{"
      assert R.field(report, :replay) == term
      assert term == expected_term(report, R.ExternalModel)

      leaves = Enum.flat_map(term.choices["second"], & &1.commands)
      assert Enum.any?(leaves, &match?(%R.Credit{account_id: %PropertyDamage.Placeholder{}}, &1))
    end

    test "a divergence is recorded as data: the mismatch exception never reaches the file" do
      report = failing()
      assert %PropertyDamage.ComparisonMismatch{} = report.failure_reason.type.mismatch

      path = R.replay_path!(report)
      text = File.read!(path)

      refute text =~ "ComparisonMismatch"
      refute text =~ "PropertyDamage.Failure"

      assert R.term!(path).failure == %{
               kind: :diverged,
               name: {F.Totals, :totals},
               variant_index: 1,
               root_index: report.failed_at_index
             }
    end
  end

  describe "determinism" do
    test "two generations of the same failure write the same bytes, with no timestamp" do
      first = failing() |> R.replay_path!() |> File.read!()
      second = failing() |> R.replay_path!() |> File.read!()

      assert first == second
      refute first =~ ~r/\d{4}-\d{2}-\d{2}/
    end

    test "a later failure of the same seed overwrites the file" do
      dir = R.tmp_dir!()
      report = failing(replay_dir: dir)
      path = R.replay_path!(report)
      written = File.read!(path)

      File.write!(path, "stale")
      again = failing(replay_dir: dir)

      assert R.field(again, :replay_path) == path
      assert File.read!(path) == written
      assert R.files(dir) == [R.artifact_name(report)]
    end
  end

  describe "options" do
    test "shrink: false writes the unshrunk run, and the footer says so" do
      report = failing(shrink: false)
      term = R.term!(R.replay_path!(report))

      assert report.shrink_iterations == 0
      assert Enum.map(term.roots, & &1.command) == Sequence.to_list(report.original_sequence)
      assert term == expected_term(report, @model)

      assert Enum.any?(R.last_lines(report, 2), &(&1 =~ "unshrunk")),
             "expected the footer to say the artifact holds the unshrunk run"
    end

    test "replay_dir: false writes nothing, and the footer names the option" do
      dir = R.tmp_dir!()
      report = failing(replay_dir: false)

      assert R.field(report, :replay_path) == nil
      assert R.files(dir) == []

      assert [label, last] = R.last_lines(report, 2)
      assert label == "Replay the shrunk failure:"
      assert last =~ "replay_dir: false"
    end
  end

  describe "generation refusals" do
    for poison <- [:function, :pid, :reference, :port] do
      @poison poison
      test "a #{poison} in a command field refuses the artifact, naming where it sits" do
        model = Module.concat(R, model_name(@poison))
        dir = R.tmp_dir!()
        targets = [R.target("ref"), R.target("second", :random, %{bug: true})]

        assert {:error, report} =
                 R.run(model, targets, seed: 1, max_runs: 1, max_commands: 3, replay_dir: dir)

        F.drain()

        # The run's result is the same as without the value.
        assert report.kind == :diverged
        assert report.variant.name == "second"
        assert report.failed_at_index == 0

        field = R.poison_field(@poison)

        assert R.field(report, :replay) ==
                 {:refused, %{target: "ref", root: 0, leaf: 0, field: field}}

        assert R.field(report, :replay_path) == nil
        assert R.files(dir) == []

        assert [label, last] = R.last_lines(report, 2)
        assert label == "Replay the shrunk failure:"
        assert last =~ "refused"
        assert last =~ "payload"
      end
    end

    test "a plain value in the same field writes the artifact" do
      dir = R.tmp_dir!()
      targets = [R.target("ref"), R.target("second", :random, %{bug: true})]

      assert {:error, report} =
               R.run(R.CleanModel, targets,
                 seed: 1,
                 max_runs: 1,
                 max_commands: 3,
                 shrink: false,
                 replay_dir: dir
               )

      F.drain()
      path = R.replay_path!(report)
      [%{commands: [tag]} | _] = R.term!(path).choices["ref"]
      assert tag == %R.Tag{n: tag.n, payload: [%{note: "plain"}]}
    end
  end

  describe "fixture smoke" do
    test "ExternalModel fails at the pinned seed with placeholders in the leaves" do
      targets = [R.target("ref"), R.target("second", :random, %{bug: true})]

      assert {:error, report} =
               R.smoke_run(
                 model: R.ExternalModel,
                 targets: targets,
                 seed: @external_seed,
                 max_runs: 1,
                 max_commands: 6,
                 compare: [converge_within: 1]
               )

      F.drain()
      assert report.kind == :diverged
      leaves = Enum.flat_map(report.trace.expansion["second"], & &1.commands)
      assert Enum.any?(leaves, &match?(%R.Credit{account_id: %PropertyDamage.Placeholder{}}, &1))
    end

    test "each poisoned model fails at root 0 with the value in the leaf of every target" do
      for poison <- [:function, :pid, :reference, :port] do
        model = Module.concat(R, model_name(poison))
        targets = [R.target("ref"), R.target("second", :random, %{bug: true})]

        assert {:error, report} =
                 R.smoke_run(
                   model: model,
                   targets: targets,
                   seed: 1,
                   max_runs: 1,
                   max_commands: 3,
                   shrink: false,
                   compare: [converge_within: 1]
                 )

        F.drain()
        assert report.failed_at_index == 0

        for name <- ["ref", "second"] do
          [%{commands: [%R.Tag{payload: payload}]} | _] = report.trace.expansion[name]
          assert poisoned?(get_in_path(payload, tl(R.poison_field(poison))))
        end
      end
    end
  end

  defp model_name(:function), do: FunModel
  defp model_name(:pid), do: PidModel
  defp model_name(:reference), do: RefModel
  defp model_name(:port), do: PortModel

  defp get_in_path(value, []), do: value

  defp get_in_path(list, [index | rest]) when is_list(list),
    do: get_in_path(Enum.at(list, index), rest)

  defp get_in_path(map, [key | rest]) when is_map(map),
    do: get_in_path(Map.fetch!(map, key), rest)

  defp poisoned?(value),
    do: is_function(value) or is_pid(value) or is_reference(value) or is_port(value)
end
