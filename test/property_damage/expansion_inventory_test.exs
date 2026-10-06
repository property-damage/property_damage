defmodule PropertyDamage.ExpansionInventoryTest do
  # The commands a run can execute are derived from generation: commands/0,
  # every module the expansions produce, and the setup and teardown modules.
  # Coverage counts executed leaves under their own module and expanded roots
  # by the entry chosen; a leaf module is validated the first time it is
  # produced; Validation checks the shape of expansions/0; and the orphan-event
  # warning considers the leaves a sampled generation reached.
  #
  # Not async: the orphan-event case runs `mix pd.validate`, which runs the
  # compile task and prints to stdout.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.{Coverage, Validation}
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Broken, Credit, Noise, Pay, RecordingAdapter, Refund}

  defp model!(name, opts), do: X.define_model!(Module.concat(ExpansionB.Inventory, name), opts)

  defp run(model, targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 4,
          seed: 1,
          shrink: false,
          validate: false
        ],
        extra
      )
    )
  end

  # The entry a group of executed commands realized for its root, as
  # `{root_module, key}`, or nil for a root no expansion applies to.
  defp entry([%Refund{}]), do: {Refund, "Refund[0]"}
  defp entry([%Credit{}, %Credit{}]), do: {Refund, "Refund[1]"}
  defp entry([%Pay{}]), do: {Pay, :forced}
  defp entry([%Noise{}]), do: nil

  defp entry_counts(segments) do
    for segment <- segments,
        {_tag, group} <- X.by_root(segment),
        entry(group) != nil,
        reduce: %{} do
      acc ->
        {root, key} = entry(group)
        Map.update(acc, root, %{key => 1}, &Map.update(&1, key, 1, fn n -> n + 1 end))
    end
  end

  # The pd.validate output the orphan-event cases read, sampled once.
  setup_all do
    model = X.define_sampling_model!(ExpansionB.Inventory.SamplingModel)

    args = [inspect(model), inspect(RecordingAdapter), "--seed", "100", "--seeds", "20"]
    output = capture_io(fn -> send(self(), {:validate_status, Validate.exec(args)}) end)

    status =
      receive do
        {:validate_status, status} -> status
      after
        0 -> :no_status
      end

    {:ok, validate_status: status, lines: String.split(output, "\n")}
  end

  describe "coverage after a run" do
    test "counts executed leaves under their own module and expanded roots per entry" do
      model =
        model!(Coverage,
          commands: [Noise, Refund, Pay],
          expansions: [{Refund, &X.refund_two/2}, {Pay, &X.none/2}]
        )

      recorder = start_recorder()

      assert {:ok, stats} =
               run(model, [X.target("solo", recorder)],
                 coverage: true,
                 max_runs: 4,
                 max_commands: 6
               )

      segments = recorder |> recorded() |> X.segments("solo")
      assert length(segments) == 4
      executed = segments |> List.flatten() |> Enum.map(& &1.__struct__)
      expected = entry_counts(segments)

      # The fixture realized the rewrite and the forced identity.
      assert Map.get(expected[Refund] || %{}, "Refund[1]", 0) > 0
      assert Map.get(expected[Pay] || %{}, :forced, 0) > 0

      tracker = stats.coverage
      assert tracker.command_counts == Enum.frequencies(executed)
      assert MapSet.member?(tracker.command_modules, Credit)
      assert Coverage.command_coverage(tracker) <= 100.0
      refute Credit in Coverage.untested_commands(tracker)

      assert tracker |> Coverage.stats() |> Map.fetch!(:expansion_counts) == expected
    end
  end

  describe "a leaf module" do
    test "missing a required callback fails at its first production, and again at the second" do
      model =
        model!(BrokenLeaf,
          commands: [Refund],
          expansions: [{Refund, fn _refund, _state -> [[Broken]] end}]
        )

      produce = fn -> run(model, [X.target("solo", nil)]) end
      first = X.outcome(produce)
      second = X.outcome(produce)

      for {status, text} = outcome <- [first, second] do
        assert status in [:raised, :error], "expected a generation error, got #{inspect(outcome)}"
        assert text =~ "Refund"
        assert text =~ "Refund[0]"
        assert text =~ "Broken"
        assert text =~ "generator/1"
      end

      assert elem(first, 0) == elem(second, 0)
    end

    test "with an overrides: key it does not define fails naming the key" do
      model =
        model!(BadKeyLeaf,
          commands: [Refund],
          expansions: [{Refund, fn _refund, _state -> [[{Credit, overrides: %{bogus: 1}}]] end}]
        )

      assert {status, text} = outcome = X.outcome(fn -> run(model, [X.target("solo", nil)]) end)
      assert status in [:raised, :error], "expected a generation error, got #{inspect(outcome)}"
      assert text =~ "bogus"
      assert text =~ "Credit"
    end
  end

  describe "Validation.validate!/3 checks the shape of expansions/0" do
    test "accepts a well-formed expansions/0" do
      model = model!(GoodShape, expansions: [{Refund, &X.refund_two/2}])
      assert {:ok, _warnings} = Validation.validate!(model, RecordingAdapter)
    end

    test "rejects a function of the wrong arity" do
      model = model!(WrongArity, expansions: [{Refund, fn refund -> [[refund]] end}])

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, RecordingAdapter) end
      assert error.message =~ "expansions"
      assert error.message =~ "Refund"
    end

    test "rejects a key that is not in commands/0" do
      model = model!(NonRootKey, expansions: [{Credit, fn credit, _state -> [[credit]] end}])

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, RecordingAdapter) end
      assert error.message =~ "expansions"
      assert error.message =~ "Credit"
    end

    test "rejects a key listed twice" do
      model =
        model!(DuplicateKey,
          expansions: [{Refund, &X.refund_two/2}, {Refund, &X.refund_rewrite/2}]
        )

      error = assert_raise ArgumentError, fn -> Validation.validate!(model, RecordingAdapter) end
      assert error.message =~ "expansions"
      assert error.message =~ "Refund"
    end
  end

  describe "the orphan-event warning in pd.validate" do
    test "warns for an unhandled event of a leaf the sample reached", %{lines: lines} = ctx do
      assert ctx.validate_status == :ok
      assert Enum.any?(lines, &(&1 =~ "Authorized" and &1 =~ "produced but not handled"))
    end

    test "does not report a handled event that only a reached leaf produces", %{lines: lines} do
      refute Enum.any?(lines, &(&1 =~ "Credited" and &1 =~ "not handled"))
    end

    test "says so for the event of a leaf the sample never reached", %{lines: lines} do
      assert Enum.any?(lines, &(&1 =~ "Haunted" and &1 =~ ~r/not (reached|realized)/))
    end
  end
end
