defmodule PropertyDamage.OnlyOptionTest do
  # The `only:` run option runs part of a campaign: `only: [run: n]` runs run
  # n of the seed and nothing else, `variants:` restricts which targets run
  # (the reference runs too unless `with_reference: false`), and every target
  # still runs the sequence `PropertyDamage.Expansion.for/5` regenerates for
  # its name. Every misuse of `only:` is an option error raised before any
  # adapter is set up.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.ExpansionFor, as: F

  @model F.Model

  # Seed 2 was found with a bounded search over 1..200 (see the
  # fixture smoke test in expansion_for_test.exs): in run 3, "second" realizes
  # Refund[1], so `bug: :credit` on "second" fails that run.
  @seed 2
  @max_commands 8

  defp entries(specs), do: for({name, mode} <- specs, do: F.target(name, mode))

  defp three, do: entries([{"ref", :random}, {"second", :random}, {"third", :random}])

  defp run(targets, opts, model \\ @model) do
    PropertyDamage.run(
      [model: model, targets: targets, seed: @seed, max_commands: @max_commands] ++ opts
    )
  end

  defp regenerated(seed, run, name, targets) do
    assert {:ok, result} =
             F.expansion_for(@model, seed, run, name,
               targets: targets,
               max_commands: @max_commands
             )

    result.sequence
  end

  # What each named target executed in a passing `max_runs: runs` campaign:
  # `%{name => [commands per run]}`.
  defp campaign(targets, runs) do
    assert {:ok, _stats} = run(targets, max_runs: runs)
    messages = F.drain()
    Map.new(["ref", "second", "third"], &{&1, F.segments(messages, &1)})
  end

  # The message of the option error `opts` raises. Fails unless the error is
  # raised before any adapter is set up and is not the error for an unknown
  # `only:` key.
  defp option_error(opts, targets \\ three(), model \\ @model) do
    assert {:raised, error} = F.outcome(fn -> run(targets, opts, model) end)
    assert error.__struct__ in [ArgumentError, NimbleOptions.ValidationError]
    message = Exception.message(error)
    refute message =~ "unknown options [:only]", message
    refute_received {:setup, _}
    message
  end

  # Each fragment is a string the message contains, or a list of strings it
  # contains one of.
  defp assert_names(message, fragments) do
    for fragment <- List.wrap(fragments) do
      alternatives = List.wrap(fragment)

      assert Enum.any?(alternatives, &String.contains?(message, &1)),
             "expected the message to contain #{Enum.map_join(alternatives, " or ", &inspect/1)}: " <>
               message
    end
  end

  defp missing_artifact do
    Path.join(System.tmp_dir!(), "missing_#{System.unique_integer([:positive])}.replay.exs")
  end

  describe "only: [run: n]" do
    test "runs run n of the seed once, the sequence Expansion.for/5 regenerates" do
      targets = three()
      assert {:ok, _stats} = run(targets, only: [run: 3])
      messages = F.drain()

      for name <- ["ref", "second", "third"] do
        assert F.setups(messages, name) == 1, "#{name} ran #{F.setups(messages, name)} times"
        [executed] = F.segments(messages, name)

        assert F.without_suffix(executed) == regenerated(@seed, 3, name, targets),
               "#{name} did not run the regenerated sequence of run 3"
      end
    end

    test "runs what run n of a max_runs: n campaign runs" do
      targets = three()
      campaign = campaign(targets, 3)

      assert {:ok, _stats} = run(targets, only: [run: 3])
      messages = F.drain()

      for name <- ["ref", "second", "third"] do
        assert F.segments(messages, name) == [Enum.at(campaign[name], 2)]
      end

      assert Enum.at(campaign["ref"], 2) != Enum.at(campaign["second"], 2)
    end

    test "max_runs: 1 beside only: is legal" do
      targets = three()
      campaign = campaign(targets, 2)

      assert {:ok, _stats} = run(targets, only: [run: 2], max_runs: 1)
      messages = F.drain()

      for name <- ["ref", "second", "third"] do
        assert F.segments(messages, name) == [Enum.at(campaign[name], 1)]
      end
    end
  end

  describe "only: [variants: names]" do
    test "runs the named targets and the reference, run 1 by default" do
      targets = three()
      assert {:ok, _stats} = run(targets, only: [variants: ["second"]])
      messages = F.drain()

      assert F.setups(messages, "ref") == 1
      assert F.setups(messages, "second") == 1
      assert F.setups(messages, "third") == 0

      for name <- ["ref", "second"] do
        [executed] = F.segments(messages, name)
        assert F.without_suffix(executed) == regenerated(@seed, 1, name, targets)
      end

      # The reference still runs, so the comparison still happens.
      assert_received {:compared, "second"}
    end

    test "with_reference: false runs the one named target alone, with no @compare call" do
      targets = three()

      assert {:ok, _stats} =
               run(targets, only: [run: 3, variants: ["second"], with_reference: false])

      messages = F.drain()

      assert F.setups(messages, "ref") == 0
      assert F.setups(messages, "second") == 1
      assert F.setups(messages, "third") == 0

      [executed] = F.segments(messages, "second")
      assert F.without_suffix(executed) == regenerated(@seed, 3, "second", targets)

      refute_received {:compared, _}
    end

    test "a :reference target that runs alone still runs the reference's sequence" do
      targets = entries([{"ref", :random}, {"second", :random}, {"third", :reference}])

      assert {:ok, _stats} =
               run(targets, only: [variants: ["third"], with_reference: false])

      messages = F.drain()

      assert F.setups(messages, "ref") == 0
      assert F.setups(messages, "third") == 1

      [executed] = F.segments(messages, "third")
      assert F.without_suffix(executed) == regenerated(@seed, 1, "ref", targets)
      assert F.without_suffix(executed) != regenerated(@seed, 1, "second", targets)
    end

    test "with_reference: false needs no @compare function" do
      targets = entries([{"a", :random}, {"b", :random}])

      assert {:ok, _stats} =
               run(targets, [only: [variants: ["b"], with_reference: false]], F.PlainModel)

      messages = F.drain()
      assert F.setups(messages, "a") == 0
      assert F.setups(messages, "b") == 1
    end
  end

  describe "the result" do
    test "a failing run's report carries the effective seed and the campaign run" do
      targets = [F.target("ref"), F.target("second", :random, %{bug: :credit})]

      assert {:error, report} =
               run(targets,
                 only: [run: 3],
                 compare: [converge_within: 1],
                 shrink: false
               )

      assert report.seed == F.run_seed_for(@seed, 3)
      assert F.report_run(report) == 3

      # The report's coordinates regenerate the failing run.
      {seed, run} = F.report_coordinates(report)
      second = regenerated(seed, run, "second", targets)
      assert second == regenerated(@seed, 3, "second", targets)

      [executed | _] = F.segments(F.drain(), "second")
      assert List.starts_with?(second, F.without_suffix(executed))
    end
  end

  describe "option errors" do
    test "with_reference: false with two names, the reference alone, or no name" do
      for variants <- [["second", "third"], ["ref"], []] do
        message = option_error(only: [variants: variants, with_reference: false])
        assert_names(message, ["with_reference: false", "exactly one"])
      end
    end

    test "a name not in targets: is an error naming it" do
      message = option_error(only: [variants: ["ghost"]])
      assert_names(message, ["ghost", "targets:"])
    end

    test "max_runs: other than 1 beside only: names both" do
      for only <- [[run: 1], [replay: missing_artifact()]] do
        message = option_error(only: only, max_runs: 3)
        assert_names(message, ["only:", "max_runs:"])
      end
    end

    test "seed: beside only: [replay: path] names both, before the path is read" do
      message = option_error(only: [replay: missing_artifact()], seed: 3)
      assert_names(message, ["seed:", "replay:"])
    end

    test "branching: beside either shape names both" do
      targets = [F.target("solo")]

      for only <- [[run: 1], [replay: missing_artifact()]] do
        message =
          option_error(
            [only: only, branching: [max_branches: 2]],
            targets,
            F.PlainModel
          )

        assert_names(message, ["branching:", "only:"])
      end
    end

    test "a shape that is neither run/variants nor replay" do
      assert_names(option_error(only: [foo: 1]), ["only:", "foo"])
      assert_names(option_error(only: [run: 1, replay: "x"]), ["only:", "run:", "replay:"])
    end

    test "run: 0" do
      assert_names(option_error(only: [run: 0]), [["run:", ":run"], "positive integer"])
    end
  end

  describe "fixture smoke" do
    test "a model without @compare cannot run two targets without only:" do
      targets = entries([{"a", :random}, {"b", :random}])

      assert {:raised, %ArgumentError{message: message}} =
               F.outcome(fn -> run(targets, [max_runs: 1], F.PlainModel) end)

      assert message =~ "declares no @compare"
    end

    test "the @compare function reports each call when two targets run" do
      assert {:ok, _stats} = run(entries([{"ref", :random}, {"second", :random}]), max_runs: 1)
      assert_received {:compared, "ref"}
      assert_received {:compared, "second"}
    end
  end
end
