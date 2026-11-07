defmodule PropertyDamage.ReplayOptionTest do
  # `only: [replay: path]` runs the failure a replay artifact records: every
  # target executes the recorded setup commands and its recorded concrete
  # commands, with no new draw, so each target's `expansion:` no longer
  # matters. A replay that fails the same way reproduces the artifact; one
  # that passes says the artifact did not reproduce. The `targets:` must name
  # exactly the recorded targets, and every misuse is an option error raised
  # before any adapter is set up.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @model F.Model
  @seed 2
  @max_commands 8

  defp targets(modes \\ {:random, :random}, bug \\ :credit) do
    {ref, second} = modes
    [F.target("ref", ref), F.target("second", second, %{bug: bug})]
  end

  # A shrunk failure and its artifact; the recorder messages of that run are
  # discarded.
  defp artifact! do
    assert {:error, report} =
             R.run(@model, targets(),
               seed: @seed,
               max_runs: 1,
               max_commands: @max_commands,
               replay_dir: R.tmp_dir!()
             )

    F.drain()
    path = R.replay_path!(report)
    {report, path, R.term!(path)}
  end

  defp replay(path, targets, opts \\ []) do
    PropertyDamage.run(
      [
        model: @model,
        targets: targets,
        only: [replay: path],
        replay_dir: R.tmp_dir!(),
        compare: [converge_within: 1]
      ] ++ opts
    )
  end

  defp identity(report) do
    {report.kind, Failure.name(report.failure_reason), report.variant.name}
  end

  # The message of the option error a replay with `targets` raises. Fails
  # unless it is raised before any adapter is set up.
  defp option_error(path, targets) do
    assert {:raised, error} = F.outcome(fn -> replay(path, targets) end)
    assert error.__struct__ in [ArgumentError, NimbleOptions.ValidationError]
    refute_received {:setup, _}
    Exception.message(error)
  end

  describe "a replay of a failing run's artifact" do
    test "reproduces the failure at the same root, and the footer says so" do
      {report, path, term} = artifact!()

      assert {:error, replayed} = replay(path, targets())
      assert identity(replayed) == identity(report)
      assert replayed.variant.index == term.failure.variant_index
      assert replayed.failed_at_index == term.failure.root_index
      assert replayed.failed_at_index == report.failed_at_index

      assert R.text(replayed) =~ "artifact reproduced"
    end

    test "does not shrink unless asked" do
      {_report, path, _term} = artifact!()

      assert {:error, replayed} = replay(path, targets())
      assert replayed.shrink_iterations == 0
    end

    test "every target executes the recorded setup commands and its recorded commands" do
      {_report, path, term} = artifact!()

      assert {:error, _replayed} = replay(path, targets())
      messages = F.drain()

      for name <- ["ref", "second"] do
        segments = F.segments(messages, name)
        assert segments != []

        for executed <- segments do
          assert F.without_suffix(executed) == R.concrete(term, name),
                 "#{name} did not execute what the artifact records"
        end
      end

      # The recorded commands include the rewrite's leaves.
      assert Enum.any?(R.concrete(term, "second"), &is_struct(&1, F.Credit))
    end

    test "ignores each target's expansion: (the recorded choices win)" do
      {report, path, term} = artifact!()

      assert {:error, replayed} = replay(path, targets({:identity, :identity}))
      assert identity(replayed) == identity(report)
      assert replayed.failed_at_index == term.failure.root_index

      messages = F.drain()

      for name <- ["ref", "second"], executed <- F.segments(messages, name) do
        assert F.without_suffix(executed) == R.concrete(term, name)
      end
    end

    test "shrink: true beside replay: runs and keeps the failure's identity" do
      {report, path, _term} = artifact!()

      assert {:error, replayed} = replay(path, targets(), shrink: true)
      assert identity(replayed) == identity(report)
    end

    test "with the bug switched off passes and says the artifact did not reproduce" do
      {_report, path, _term} = artifact!()

      assert {:ok, stats} = replay(path, targets({:random, :random}, false))
      assert R.field(stats, :replay) == :not_reproduced
    end

    test "writes no artifact of its own" do
      {_report, path, _term} = artifact!()
      written = File.read!(path)
      dir = R.tmp_dir!()

      assert {:error, _replayed} =
               PropertyDamage.run(
                 model: @model,
                 targets: targets(),
                 only: [replay: path],
                 replay_dir: dir,
                 compare: [converge_within: 1]
               )

      assert R.files(dir) == []
      assert File.read!(path) == written
    end
  end

  describe "option errors, before any adapter is set up" do
    test "targets: missing a recorded name names it" do
      {_report, path, _term} = artifact!()
      message = option_error(path, [F.target("ref")])
      assert message =~ ~s("second")
    end

    test "a target the artifact does not record names it" do
      {_report, path, _term} = artifact!()
      message = option_error(path, targets() ++ [F.target("third")])
      assert message =~ ~s("third")
    end

    test "a path that does not exist names the path" do
      path = Path.join(R.tmp_dir!(), "absent_seed1.replay.exs")
      message = option_error(path, targets())
      assert message =~ "absent_seed1.replay.exs"
    end

    test "a file the loader refuses surfaces the loader's reason" do
      {_report, path, _term} = artifact!()
      touched = Path.join(R.tmp_dir!(), "touched")
      text = File.read!(path)

      File.write!(
        path,
        String.replace(text, "run: 1", ~s|run: System.cmd("touch", [#{inspect(touched)}])|)
      )

      message = option_error(path, targets())
      assert message =~ "System.cmd"
      refute File.exists?(touched)
    end
  end

  describe "fixture smoke" do
    test "the failing run fails in the second target where it ran the rewrite" do
      assert {:error, report} =
               R.smoke_run(
                 model: @model,
                 targets: targets(),
                 seed: @seed,
                 max_runs: 1,
                 max_commands: @max_commands,
                 compare: [converge_within: 1]
               )

      F.drain()
      assert %FailureReport{kind: :diverged, variant: %{name: "second"}} = report

      assert %{entry: "Refund[1]"} =
               Enum.at(report.expansions["second"], report.failed_at_index)
    end

    test "with the bug switched off the same seed passes" do
      assert {:ok, _stats} =
               R.smoke_run(
                 model: @model,
                 targets: targets({:random, :random}, false),
                 seed: @seed,
                 max_runs: 1,
                 max_commands: @max_commands,
                 compare: [converge_within: 1]
               )

      F.drain()
    end
  end
end

defmodule PropertyDamage.ReplayDocumentedOptionsTest do
  # The options `Replay.run/2` and `Replay.start/2` document are the ones
  # their schema accepts: a documented option must not raise, and an option
  # the schema rejects must not be documented.
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Replay}

  @rejected [:stutter_config, :external_markers]

  defp docs_of(fun_or_moduledoc) do
    {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(Replay)

    case fun_or_moduledoc do
      :moduledoc ->
        %{"en" => text} = moduledoc
        text

      {name, arity} ->
        {_, _, _, %{"en" => text}, _} =
          Enum.find(entries, fn {{kind, n, a}, _, _, _, _} ->
            kind == :function and n == name and a == arity
          end)

        text
    end
  end

  for opt <- @rejected do
    test "#{opt} is rejected before the report is read" do
      assert_raise NimbleOptions.ValidationError,
                   ~r/unknown options \[#{inspect(unquote(opt))}\]/,
                   fn ->
                     Replay.start(%FailureReport{}, [{unquote(opt), []}])
                   end
    end

    test "#{opt} is not documented as a replay option" do
      for doc <- [docs_of(:moduledoc), docs_of({:run, 2}), docs_of({:start, 2})] do
        refute doc =~ "`#{inspect(unquote(opt))}`"
      end
    end
  end

  test "every option the run/2 docs list passes validation" do
    listed =
      ~r/^- `:(\w+)`/m
      |> Regex.scan(docs_of({:run, 2}), capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_existing_atom/1)

    assert :targets in listed and :log in listed

    schema_keys = [:targets, :stop_on_failure, :include_projections, :log]
    assert Enum.sort(listed) == Enum.sort(schema_keys)
  end
end
