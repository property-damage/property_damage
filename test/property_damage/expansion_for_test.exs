defmodule PropertyDamage.ExpansionForTest do
  # `PropertyDamage.Expansion.for(model, seed, run, name, opts)` regenerates
  # the concrete sequence one named target runs in run `run` of a campaign
  # seeded with `seed`: the setup prefix, the roots, the target's choices and
  # the commands it executes, without running any target. A recording adapter
  # proves the result equals what the target executed.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Expansion, Options}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ExpansionFor.{Close, Credit, Fund, Noise, Refund}

  @model F.Model

  # Seed 2 was found with a bounded search over 1..200: in runs 1
  # and 3, "ref" realizes both Refund entries, "second" realizes Refund[1] and
  # differs from "ref", the prefix differs between the runs, and "renamed"
  # draws differently from "second".
  @seed 2
  @max_commands 8
  @runs 3

  # What "second" (`:random`, beside a `:random` "ref") runs in run 1 of seed
  # 2 with 8 commands, computed once in a separate OS process from the
  # generator and `Expansion.expand/5`.
  @golden_run1_second [
    %Fund{amount: 382_810},
    %Noise{n: 661_646},
    %Credit{amount: 435, part: 0, memo: 79_780_156},
    %Credit{amount: 435, part: 1, memo: 432_977_189},
    %Refund{amount: 824},
    %Noise{n: 256_369},
    %Refund{amount: 22},
    %Refund{amount: 392},
    %Noise{n: 879_868},
    %Refund{amount: 516}
  ]
  @golden_run1_second_entries [
    nil,
    "Refund[1]",
    "Refund[0]",
    nil,
    "Refund[0]",
    "Refund[0]",
    nil,
    "Refund[0]"
  ]
  @golden_run3_second_entries [nil, "Refund[1]", nil, "Refund[0]", nil, nil, "Refund[1]", nil]

  defp entries(specs), do: for({name, mode} <- specs, do: F.target(name, mode))

  defp expand_for!(seed, run, name, opts) do
    assert {:ok, result} = F.expansion_for(@model, seed, run, name, opts)
    result
  end

  # Runs a passing `max_runs: 3` campaign and returns what each target
  # executed: `%{name => [commands of run 1, run 2, run 3]}`.
  defp campaign(entries) do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: @model,
               targets: entries,
               seed: @seed,
               max_runs: @runs,
               max_commands: @max_commands
             )

    messages = F.drain()

    Map.new(entries, fn {_adapter, opts} ->
      name = Keyword.fetch!(opts, :name)
      {name, F.segments(messages, name)}
    end)
  end

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)

  defp leaves?(commands), do: Enum.any?(commands, &is_struct(&1, Credit))

  describe "the result equals what each target executed" do
    test "every target of a three-target run, in run 1 and in run 3" do
      targets =
        entries([{"ref", :random}, {"second", :random}, {"third", :reference}])

      executed = campaign(targets)

      for name <- ["ref", "second", "third"], run <- [1, @runs] do
        assert length(executed[name]) == @runs
        recorded = F.without_suffix(Enum.at(executed[name], run - 1))
        result = expand_for!(@seed, run, name, targets: targets, max_commands: @max_commands)

        assert result.sequence == recorded,
               "#{name}, run #{run}: Expansion.for/5 differs from what the target executed"
      end

      # The targets ran different paths, so the equalities above are not one
      # sequence compared with itself.
      for run <- [0, @runs - 1] do
        assert leaves?(Enum.at(executed["ref"], run))
        assert leaves?(Enum.at(executed["second"], run))
        assert Enum.at(executed["ref"], run) != Enum.at(executed["second"], run)
        assert Enum.at(executed["third"], run) == Enum.at(executed["ref"], run)
      end
    end

    test "an :identity target, in run 1 and in run 3" do
      targets = entries([{"ref", :random}, {"plain", :identity}])
      executed = campaign(targets)

      for run <- [1, @runs] do
        recorded = F.without_suffix(Enum.at(executed["plain"], run - 1))
        result = expand_for!(@seed, run, "plain", targets: targets, max_commands: @max_commands)

        assert result.sequence == recorded
        refute leaves?(recorded)
      end
    end
  end

  describe "the result's shape" do
    test "prefix, roots, choices in root order and the concrete sequence" do
      targets = entries([{"ref", :random}, {"second", :random}])
      result = expand_for!(@seed, 1, "second", targets: targets, max_commands: @max_commands)
      generated = F.generated(@model, @seed, 1, @max_commands)
      roots = F.roots(@model, @seed, 1, @max_commands)

      assert result |> Map.keys() |> Enum.sort() == [:choices, :prefix, :roots, :sequence]
      assert result.prefix == generated.setup
      assert result.roots == roots

      assert Enum.map(result.choices, & &1.root_id) ==
               Enum.to_list(0..(length(roots) - 1))

      assert Enum.map(result.choices, & &1.entry) == @golden_run1_second_entries

      assert result.sequence ==
               result.prefix ++ Enum.flat_map(result.choices, & &1.commands)
    end

    test "matches the sequence computed in another OS process" do
      targets = entries([{"ref", :random}, {"second", :random}])

      assert expand_for!(@seed, 1, "second", targets: targets, max_commands: @max_commands).sequence ==
               @golden_run1_second

      assert Enum.map(
               expand_for!(@seed, 3, "second", targets: targets, max_commands: @max_commands).choices,
               & &1.entry
             ) == @golden_run3_second_entries
    end
  end

  describe "names and expansion modes" do
    test "a :random name without targets: equals the same name inside a two-target run" do
      targets = entries([{"ref", :random}, {"second", :random}])

      for run <- [1, @runs] do
        alone = expand_for!(@seed, run, "second", max_commands: @max_commands)
        inside = expand_for!(@seed, run, "second", targets: targets, max_commands: @max_commands)
        assert alone == inside
      end
    end

    test "the four-argument call is the five-argument call with no options" do
      args = [@model, @seed, 1, "second"]
      assert {:ok, _result} = four = apply(F.expansion_module(), :for, args)
      assert four == F.expansion_for(@model, @seed, 1, "second", [])
    end

    test ":identity returns the roots after the prefix" do
      targets = entries([{"ref", :random}, {"plain", :identity}])
      result = expand_for!(@seed, 1, "plain", targets: targets, max_commands: @max_commands)

      assert result.sequence ==
               result.prefix ++ F.roots(@model, @seed, 1, @max_commands)
    end

    test ":reference returns the reference's concrete sequence" do
      targets = entries([{"ref", :random}, {"second", :random}, {"third", :reference}])
      opts = [targets: targets, max_commands: @max_commands]

      third = expand_for!(@seed, 1, "third", opts)
      ref = expand_for!(@seed, 1, "ref", opts)
      second = expand_for!(@seed, 1, "second", opts)

      assert third.sequence == ref.sequence
      assert leaves?(third.sequence)
      assert third.sequence != second.sequence
    end

    test "reordering targets: keeps every named :random result" do
      first = entries([{"ref", :random}, {"second", :random}, {"third", :random}])
      again = entries([{"third", :random}, {"second", :random}, {"ref", :random}])

      for name <- ["ref", "second", "third"], run <- [1, @runs] do
        assert expand_for!(@seed, run, name, targets: first, max_commands: @max_commands) ==
                 expand_for!(@seed, run, name, targets: again, max_commands: @max_commands),
               "#{name}, run #{run} changed when the targets were reordered"
      end
    end

    test "renaming a target changes its result and keeps the others'" do
      before = entries([{"ref", :random}, {"second", :random}])
      renamed = entries([{"ref", :random}, {"renamed", :random}])
      opts = &[targets: &1, max_commands: @max_commands]

      assert expand_for!(@seed, 1, "second", opts.(before)).sequence !=
               expand_for!(@seed, 1, "renamed", opts.(renamed)).sequence

      assert expand_for!(@seed, 1, "ref", opts.(before)) ==
               expand_for!(@seed, 1, "ref", opts.(renamed))
    end
  end

  describe "errors" do
    test "a name not in targets: is an error naming it" do
      targets = entries([{"ref", :random}, {"second", :random}])

      assert {:error, reason} =
               F.expansion_for(@model, @seed, 1, "ghost",
                 targets: targets,
                 max_commands: @max_commands
               )

      assert text(reason) =~ "ghost"
    end

    test "a module that is not a model is an error naming it" do
      assert {:error, reason} = F.expansion_for(Noise, @seed, 1, "second", [])
      assert text(reason) =~ inspect(Noise)
    end

    test "an unknown option key is an error naming it" do
      assert {:error, reason} =
               F.expansion_for(@model, @seed, 1, "second", bogus_option: true)

      assert text(reason) =~ "bogus_option"
    end

    test "run 0 is an error naming the run" do
      assert {:error, reason} = F.expansion_for(@model, @seed, 0, "second", [])
      assert text(reason) =~ "run"
    end
  end

  describe "the prefix and the suffix" do
    test "the prefix holds the setup commands with their generated arguments; no suffix" do
      targets = entries([{"ref", :random}, {"second", :random}])
      executed = campaign(targets)

      run1 = expand_for!(@seed, 1, "second", targets: targets, max_commands: @max_commands)
      run3 = expand_for!(@seed, @runs, "second", targets: targets, max_commands: @max_commands)

      for {result, run} <- [{run1, 1}, {run3, @runs}] do
        generated = F.generated(@model, @seed, run, @max_commands)
        recorded = Enum.at(executed["second"], run - 1)

        assert [%Fund{}] = result.prefix
        assert result.prefix == generated.setup
        assert Enum.take(recorded, 1) == result.prefix
        assert List.starts_with?(result.sequence, result.prefix)

        # The suffix ran, and the result leaves it out.
        assert [%Close{}] = generated.teardown
        assert is_struct(List.last(recorded), Close)
        refute Enum.any?(result.sequence, &is_struct(&1, Close))
      end

      # The prefix argument is generated per run.
      assert run1.prefix != run3.prefix
    end
  end

  describe "it runs no target" do
    test "no adapter is set up and no command executed" do
      targets = entries([{"ref", :random}, {"second", :random}, {"third", :reference}])

      for name <- ["ref", "second", "third"] do
        expand_for!(@seed, 1, name, targets: targets, max_commands: @max_commands)
      end

      refute_received {:setup, _}
      refute_received {:executed, _, _}
      refute_received {:teardown, _}
    end
  end

  describe "fixture smoke" do
    test "at the pinned seed both Refund entries are realized in runs 1 and 3" do
      {:ok, targets} =
        Options.validate_targets(entries([{"ref", :random}, {"second", :random}]))

      for run <- [1, @runs] do
        sequence = F.generated(@model, @seed, run, @max_commands)
        expansion = Expansion.expand(@model, sequence, targets, F.run_seed_for(@seed, run))
        ref = Enum.map(expansion.variants["ref"].choices, & &1.entry)
        second = Enum.map(expansion.variants["second"].choices, & &1.entry)

        assert "Refund[0]" in ref
        assert "Refund[1]" in ref
        assert "Refund[1]" in second
        assert ref != second
      end
    end

    test "the planted bug fails a plain run at the pinned seed" do
      targets = [F.target("ref"), F.target("second", :random, %{bug: :credit})]

      assert {:error, report} =
               PropertyDamage.run(
                 model: @model,
                 targets: targets,
                 seed: @seed,
                 max_runs: @runs,
                 max_commands: @max_commands,
                 compare: [converge_within: 1],
                 shrink: false
               )

      assert report.kind == :diverged
    end
  end
end
