defmodule PropertyDamage.Next.CorpusGuardrailTest do
  # The corpus entries of `corpus/next` that run a fault and the four
  # guardrail entries, on the corpus harness. A guardrail entry is found when
  # its named error is raised or its line is in the run report, and its
  # control pair, the corrected model and adapter, passes.
  #
  # async: false because the corpus support files load once for the whole VM
  # and the task prints to stdout, which is captured.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Corpus, as: CorpusTask
  alias PropertyDamage.Corpus.{Engine, Entry, Loader, Measure, Table}

  @corpus "corpus/next"
  @plan_cap 200

  @guardrails %{
    "unset_field_in_clause" => "Corpus.Next.Scheme.Refund lose_response: set",
    "unset_assign_acknowledged" => "acknowledged the assign :lose_response",
    "layer_matches_no_spec" => "lose_response_misspelled/1: specs changed: 0",
    "command_never_eligible" => "Corpus.Next.Scheme.Refund (spec 1): never eligible"
  }

  setup_all do
    {:ok, entries} = Loader.load(@corpus)
    {:ok, entries: Map.new(entries, &{&1.name, &1})}
  end

  describe "double_credit on the new engine" do
    test "the shrunk plan holds the lost response a layer set, and reaches the minimum",
         %{entries: entries} do
      entry = entries["double_credit"]
      result = Engine.Next.run(entry, 1, @plan_cap)

      assert result.found?
      assert result.bug_fired?
      assert Enum.any?(result.shrunk, &(&1[:lose_response] == true))
      assert Measure.matches_minimum?(entry, result.shrunk)
    end

    test "a plan step shows only the assigns that are truthy", %{entries: entries} do
      result = Engine.Next.run(entries["double_credit"], 1, @plan_cap)

      for step <- result.shrunk,
          step.command == :pay,
          do: refute(Map.has_key?(step, :lose_response))
    end

    test "with the bug off, passes", %{entries: entries} do
      row = Measure.seed(entries["double_credit"], 1, @plan_cap)

      assert row.clean?
    end
  end

  for {name, text} <- @guardrails do
    describe "guardrail entry #{name}" do
      test "is found with the mistake present, and the line holds its text", %{entries: entries} do
        entry = entries[unquote(name)]
        result = Engine.Next.run(entry, 1, @plan_cap)

        assert %Entry{expect: expect} = entry
        assert expect != nil
        assert result.found?
        assert result.line =~ unquote(text)
        assert Measure.seed(entry, 1, @plan_cap).found?
      end

      test "with the switch off, the corrected pair passes", %{entries: entries} do
        entry = %{entries[unquote(name)] | bug: nil}
        result = Engine.Next.run(entry, 1, @plan_cap)

        refute result.found?
        assert result.line == nil
        assert Measure.seed(entries[unquote(name)], 1, @plan_cap).clean?
      end
    end
  end

  describe "the table" do
    test "a guardrail result is sound only when every seed found its line" do
      row = %{
        seed: 1,
        found?: true,
        unexplained?: false,
        plans_until_found: nil,
        shrink_runs: 0,
        reached_minimum?: false,
        clean?: true
      }

      result = %{entry: "g", rows: [row], regression: true, guardrail: true}

      assert Table.sound?([result])
      refute Table.sound?([%{result | rows: [%{row | found?: false}]}])
    end

    test "a found seed without a plan number shows no plans in the table" do
      row = %{
        seed: 1,
        found?: true,
        unexplained?: false,
        plans_until_found: nil,
        shrink_runs: 0,
        reached_minimum?: false,
        clean?: true
      }

      assert Table.render([%{entry: "g", rows: [row], regression: true, guardrail: true}]) =~
               ~r/^g\s+1\/1\s+-\s+0\.0\s+-$/m
    end

    test "the task prints the line a guardrail entry found", %{entries: _entries} do
      output =
        capture_io(fn ->
          assert CorpusTask.exec(["--dir", @corpus, "--only", "layer_matches_no_spec"]) == :ok
        end)

      assert output =~ "guardrail lines:"

      assert output =~
               "layer_matches_no_spec: Corpus.Next.Guardrail.Layers.lose_response_misspelled/1: specs changed: 0"
    end
  end
end
