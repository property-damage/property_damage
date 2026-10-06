defmodule PropertyDamage.ExpansionAccountingTest do
  # Each variant executes its own concrete sequence. Leaves are executed
  # commands: checks, `every: N` counters and latency samples see them, while
  # the boundaries, `max_commands` and `total_commands` count roots. Setup
  # commands never expand, and `terminate_early?/3` never sees a leaf.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Capture, CaptureSeen, Credit, EveryTwo, Noise}
  alias PropertyDamage.Test.ExpansionRun.{Pay, Refund, Totals}

  defp model!(name, opts), do: X.define_model!(Module.concat(ExpansionB.Accounting, name), opts)

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 5,
          shrink: false,
          validate: false
        ],
        extra
      )
    )
  end

  defp seed!(model, max_commands, predicate) do
    X.find_seed(model, max_commands, 1..2_000, predicate) ||
      flunk("no seed in 1..2000 generates the roots this test needs")
  end

  defp refunds(roots), do: Enum.count(roots, &match?(%Refund{}, &1))

  # The one execution of `name` in a run without shrinking.
  defp executed(recorder, name) do
    assert [commands] = recorder |> recorded() |> X.segments(name)
    commands
  end

  defp rewriting_model(name, extra \\ []),
    do: model!(name, Keyword.merge([expansions: [{Refund, &X.refund_rewrite/2}]], extra))

  describe "leaves are executed commands per variant" do
    test "a check on a command module fires on that module's leaves" do
      model =
        model!(CaptureCheck,
          commands: [Noise, Pay],
          expansions: [{Pay, &X.pay_rewrite/2}],
          checks: [Totals, CaptureSeen]
        )

      seed = seed!(model, 5, &Enum.any?(&1, fn root -> match?(%Pay{}, root) end))
      recorder = start_recorder()

      assert {:ok, stats} = run(model, [X.target("solo", recorder)], seed: seed)

      captures = recorder |> executed("solo") |> Enum.count(&match?(%Capture{}, &1))
      # Every Pay root expanded into Authorize and Capture.
      assert captures >= 1
      refute recorder |> executed("solo") |> Enum.any?(&match?(%Pay{}, &1))
      assert stats.check_fires[{CaptureSeen, :capture_seen}] == captures
    end

    test "every: N counts each variant's executed commands, so the counts differ per variant" do
      model = rewriting_model(EveryTwoModel, checks: [Totals, EveryTwo])
      seed = seed!(model, 4, &(length(&1) == 4 and refunds(&1) == 2))
      recorder = start_recorder()

      assert {:ok, _stats} =
               run(
                 model,
                 [
                   X.target("alpha", recorder, %{}, expansion: :identity),
                   X.target("beta", recorder)
                 ],
                 seed: seed,
                 max_commands: 4
               )

      # The reference runs the four roots; the second variant runs two of them
      # as two leaves each.
      assert length(executed(recorder, "alpha")) == 4
      assert length(executed(recorder, "beta")) == 6

      entries = recorded(recorder)
      fires = fn name -> Enum.count(entries, &(&1 == {:every2, name})) end
      assert fires.("alpha") == 2
      assert fires.("beta") == 3
    end

    test "@compare every: 1 compares once per root in every variant" do
      model = rewriting_model(ComparePerRoot)
      seed = seed!(model, 5, &(refunds(&1) >= 1))
      recorder = start_recorder()

      assert {:ok, stats} =
               run(
                 model,
                 [
                   X.target("alpha", recorder, %{}, expansion: :identity),
                   X.target("beta", recorder)
                 ],
                 seed: seed
               )

      assert length(executed(recorder, "beta")) > 5
      assert stats.compare_counts[{Totals, :totals}].compared_at == 5

      entries = recorded(recorder)
      assert Enum.count(entries, &(&1 == {:compared, "alpha"})) == 5
      assert Enum.count(entries, &(&1 == {:compared, "beta"})) == 5
    end

    test "max_commands and total_commands count roots, however many leaves run" do
      model = rewriting_model(MaxCommands)
      seed = seed!(model, 5, &(refunds(&1) >= 2))
      recorder = start_recorder()

      assert {:ok, stats} =
               run(model, [X.target("alpha", recorder), X.target("beta", recorder)], seed: seed)

      assert stats.total_commands == 5

      for name <- ["alpha", "beta"] do
        commands = executed(recorder, name)
        assert length(X.by_root(commands)) == 5
        assert length(commands) == 5 + seed_refunds(model, seed)
      end
    end

    test "latency samples are taken per executed command and keyed by leaf module" do
      model = rewriting_model(Latency)
      seed = seed!(model, 5, &(refunds(&1) >= 1 and refunds(&1) < 5))
      recorder = start_recorder()

      assert {:ok, stats} =
               run(
                 model,
                 [
                   X.target("alpha", recorder, %{}, expansion: :identity),
                   X.target("beta", recorder)
                 ],
                 seed: seed,
                 latency: true,
                 concurrency: :serial
               )

      metrics = Map.fetch!(stats, :metrics)

      for name <- ["alpha", "beta"] do
        executed = recorder |> executed(name) |> Enum.map(& &1.__struct__)
        frequencies = Enum.frequencies(executed)

        assert metrics[name].commands == length(executed)

        assert metrics[name].by_command |> Map.keys() |> Enum.sort() ==
                 frequencies |> Map.keys() |> Enum.sort()

        for {module, count} <- frequencies do
          assert metrics[name].by_command[module].commands == count
        end
      end

      # The second variant expands every Refund root, so only its leaves are
      # samples.
      assert Map.has_key?(metrics["beta"].by_command, Credit)
      refute Map.has_key?(metrics["beta"].by_command, Refund)
      assert Map.has_key?(metrics["alpha"].by_command, Refund)
    end
  end

  describe "setup commands" do
    test "are never expanded, while the same module expands where it is a root" do
      model = rewriting_model(SetupRefund, commands: [Refund], setup: [Refund])
      recorder = start_recorder()

      assert {:ok, _stats} =
               run(model, [X.target("alpha", recorder), X.target("beta", recorder)],
                 seed: 7,
                 max_commands: 3
               )

      for name <- ["alpha", "beta"] do
        assert [%Refund{} | roots] = executed(recorder, name)
        refute Enum.any?(roots, &match?(%Refund{}, &1))
        assert Enum.count(roots, &match?(%Credit{}, &1)) == 6
      end
    end
  end

  describe "terminate_early?/3" do
    test "is never consulted for a leaf" do
      model = rewriting_model(Terminate, terminate: true)
      seed = seed!(model, 5, fn roots -> roots |> Enum.take(4) |> refunds() >= 1 end)
      drain_terminate_messages()
      recorder = start_recorder()

      assert {:ok, stats} = run(model, [X.target("solo", recorder)], seed: seed)

      commands = executed(recorder, "solo")
      assert Enum.any?(commands, &match?(%Credit{}, &1))
      assert stats.total_commands == 5
      assert length(X.by_root(commands)) == 5
      refute_received {:terminate_consulted, %Credit{}}
    end
  end

  defp seed_refunds(model, seed), do: model |> X.roots(seed, 5) |> refunds()

  defp drain_terminate_messages do
    receive do
      {:terminate_consulted, _} -> drain_terminate_messages()
    after
      0 -> :ok
    end
  end
end
