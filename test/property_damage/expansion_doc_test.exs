defmodule PropertyDamage.ExpansionDocTest do
  # An entry of an expansion function can carry a `doc:` that describes the
  # whole route. The doc rides the realized choice (its `:doc` key) wherever a
  # choice is built: a draw, a listed identity, a copy of the reference, a
  # carried choice, a shrunk report.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.{Expansion, FailureReport, Generator}
  alias PropertyDamage.Test.Expansion, as: X

  alias PropertyDamage.Test.Expansion.{
    Authorize,
    Blocked,
    Capture,
    Credit,
    Pay,
    Recorder,
    Skip
  }

  @two_halves "refund in two halves"
  @as_is "the payment as it is"
  @two_steps "authorize, then capture"

  defp model!(name, opts), do: X.define_model!(Module.concat(ExpansionDoc, name), opts)

  defp credits(a), do: [{Credit, overrides: %{amount: a}}]

  defp halves(a) do
    half = div(a, 2)
    [{Credit, overrides: %{amount: half}}, {Credit, overrides: %{amount: a - half}}]
  end

  defp authorize_capture(a) do
    [
      {Authorize, overrides: %{amount: a}},
      {Capture,
       overrides: fn _state, [%{events: [%X.Authorized{id: id}]}] ->
         %{authorization_id: id, amount: a}
       end}
    ]
  end

  # The entries every test below draws from: the root as it is (weight 3) and
  # an authorization with its capture, each with its own doc.
  defp documented(%Pay{amount: a} = pay, _state) do
    [
      {[pay], weight: 3, doc: @as_is},
      {authorize_capture(a), doc: @two_steps}
    ]
  end

  defp documented_model(name), do: model!(name, expansions: [{Pay, &documented/2}])

  defp sequence_of(model, seed, max_commands) do
    model
    |> Generator.generate_sequence(max_commands: max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, 0))
  end

  # What `Expansion.for/5` realizes for target `name` of `model` at `seed`.
  defp choices!(model, seed, name \\ "a", opts \\ []) do
    assert {:ok, %{choices: choices}} =
             Expansion.for(model, seed, 1, name, Keyword.put_new(opts, :max_commands, 6))

    choices
  end

  defp doc!(choice), do: Map.fetch!(choice, :doc)

  # The first seed whose run with `fail: Capture` fails, as a report.
  defp failing_report!(model, opts \\ []) do
    Enum.find_value(1..200, fn seed ->
      recorder = start_recorder()
      target = X.target("solo", recorder, nil, %{fail: %{Capture => :error}})

      case X.run(model, [target], Keyword.merge([seed: seed, max_commands: 4], opts)) do
        {:error, %FailureReport{} = report} -> report
        {:ok, _stats} -> nil
      end
    end) || flunk("no seed in 1..200 ran the authorization entry")
  end

  describe "entry options" do
    test "a doc alone is accepted, the weight defaults to 1 and the choice carries the doc" do
      model =
        model!(DocOnly,
          expansions: [{Pay, fn %Pay{amount: a}, _state -> [{halves(a), doc: @two_halves}] end}]
        )

      assert {:ok, _stats} =
               X.run(model, [X.target("a", start_recorder())], max_runs: 3)

      choices = choices!(model, 1)
      assert [_ | _] = choices

      for choice <- choices do
        assert choice.entry == "Pay[0]"
        assert doc!(choice) == @two_halves
      end
    end

    test "a doc beside a weight is accepted and the weight still counts" do
      heavy = fn %Pay{amount: a}, _state ->
        [{halves(a), weight: 50, doc: @two_halves}, [{Credit, overrides: %{amount: a}}]]
      end

      plain = fn %Pay{amount: a}, _state ->
        [{halves(a), weight: 50}, [{Credit, overrides: %{amount: a}}]]
      end

      documented = model!(HeavyDoc, expansions: [{Pay, heavy}])
      undocumented = model!(HeavyPlain, expansions: [{Pay, plain}])

      indices = fn model ->
        for seed <- 1..30, choice <- choices!(model, seed), do: choice.index
      end

      drawn = indices.(documented)

      # The doc changes no draw: the same seeds pick the same entries.
      assert drawn == indices.(undocumented)
      assert Enum.count(drawn, &(&1 == 0)) > Enum.count(drawn, &(&1 == 1))
      assert 1 in drawn

      for seed <- 1..30, choice <- choices!(documented, seed) do
        assert doc!(choice) == if(choice.index == 0, do: @two_halves, else: nil)
      end
    end

    test "a doc that is not a string, an unknown option and a doc with an unknown option are errors" do
      bad = [
        {:not_a_string, [doc: :not_a_string]},
        {:charlist, [doc: ~c"charlist"]},
        {:colour, [colour: 1]},
        {:doc_and_colour, [weight: 1, doc: "x", colour: 1]}
      ]

      for {name, opts} <- bad do
        model =
          model!(Module.concat(BadOption, Macro.camelize("#{name}")),
            expansions: [{Pay, fn pay, _state -> [{[pay], opts}] end}]
          )

        message =
          X.error_message(fn -> X.run(model, [X.target("a", start_recorder())]) end)

        assert message =~ "Pay[0]", inspect(opts)
        assert message =~ "weight:", inspect(opts)
        assert message =~ "doc:", inspect(opts)
      end
    end

    test "an entry with an empty option list is an error naming weight: and doc:" do
      model =
        model!(EmptyOptions, expansions: [{Pay, fn pay, _state -> [{[pay], []}] end}])

      message = X.error_message(fn -> X.run(model, [X.target("a", start_recorder())]) end)

      assert message =~ "Pay[0]"
      assert message =~ "weight:"
      assert message =~ "doc:"
    end

    test "a bare sequence realizes with a doc of nil" do
      model =
        model!(Bare, expansions: [{Pay, fn %Pay{amount: a}, _state -> [halves(a)] end}])

      choices = choices!(model, 1)
      assert [_ | _] = choices

      for choice <- choices do
        assert choice.entry == "Pay[0]"
        assert Map.has_key?(choice, :doc)
        assert doc!(choice) == nil
      end
    end
  end

  describe "doc: on a leaf" do
    defp leaf_doc_model(name, leaf_options) do
      model!(name,
        expansions: [
          {Pay,
           fn %Pay{amount: a}, _state ->
             [[{Credit, leaf_options ++ [overrides: %{amount: a}]}]]
           end}
        ]
      )
    end

    test "is ignored by a run: the commands match the same model without it" do
      executed = fn model ->
        recorder = start_recorder()
        assert {:ok, _stats} = X.run(model, [X.target("a", recorder)])
        X.executed(recorded(recorder), "a")
      end

      with_doc = executed.(leaf_doc_model(LeafDoc, doc: "x"))
      without = executed.(leaf_doc_model(LeafNoDoc, []))

      assert with_doc != []
      assert with_doc == without
    end

    test "is warned on once by mix pd.validate --seeds, naming the root entry, the leaf and doc:" do
      model = leaf_doc_model(LeafDocWarned, doc: "x")

      output =
        capture_io(fn ->
          assert Validate.exec([
                   inspect(model),
                   "--targets",
                   "[#{inspect(Recorder)}]",
                   "--seeds",
                   "3",
                   "--seed",
                   "1"
                 ]) == :ok
        end)

      line = "#{inspect(Credit)} sets doc: ignored in a sequence"

      assert output =~ "Pay[0]"
      assert length(String.split(output, line)) - 1 == 1
    end

    test "is warned on once by Expansion.expand/5" do
      model = leaf_doc_model(LeafDocExpand, doc: "x")
      target = %PropertyDamage.Target{name: "a", index: 0, expansion: :random}

      %{warnings: warnings} = Expansion.expand(model, sequence_of(model, 1, 6), [target], 7)

      assert [warning] = Enum.filter(warnings, &(&1 =~ "doc"))
      assert warning =~ "Pay[0]"
      assert warning =~ inspect(Credit)
      assert warning =~ "doc:"
    end
  end

  describe "the doc of a realized choice" do
    test "follows a random draw, in Expansion.for/5 and in a run's trace" do
      model = documented_model(Drawn)

      drawn = for seed <- 1..10, choice <- choices!(model, seed), do: choice
      assert Enum.any?(drawn, &(&1.index == 0))
      assert Enum.any?(drawn, &(&1.index == 1))

      for choice <- drawn do
        assert doc!(choice) == Enum.at([@as_is, @two_steps], choice.index)
      end

      report = failing_report!(model, shrink: false)
      traced = report.trace.expansion["solo"]
      assert Enum.any?(traced, &(&1.index == 1))

      for choice <- traced do
        assert doc!(choice) == Enum.at([@as_is, @two_steps], choice.index)
      end
    end

    test "is carried by a listed identity realized as itself" do
      model =
        model!(Identity,
          expansions: [{Pay, fn pay, _state -> [{[pay], doc: "the root, unchanged"}] end}]
        )

      choices = choices!(model, 1)
      assert [_ | _] = choices

      for choice <- choices do
        assert choice.entry == "Pay[0]"
        assert choice.leaves? == false
        assert doc!(choice) == "the root, unchanged"
      end
    end

    test "is nil for a root that ran as itself because no entry could be realized" do
      model =
        model!(Forced,
          commands: [Pay, {Blocked, when: fn _state -> false end}],
          expansions: [
            {Pay,
             fn _pay, _state -> [{[{Blocked, overrides: %{amount: 1}}], doc: "never runs"}] end}
          ]
        )

      choices = choices!(model, 1)
      assert [_ | _] = choices

      for choice <- choices do
        assert choice.entry == :forced
        assert doc!(choice) == nil
      end
    end

    test "is nil for a root the model does not list" do
      model =
        model!(Unlisted,
          commands: [Pay, Skip],
          expansions: [{Pay, &documented/2}]
        )

      unlisted =
        for seed <- 1..10, choice <- choices!(model, seed), choice.module == Skip, do: choice

      assert [_ | _] = unlisted

      for choice <- unlisted do
        assert choice.entry == nil
        assert doc!(choice) == nil
      end
    end

    test "is copied by a reference target from the reference's choice at the root" do
      model = documented_model(Referenced)
      recorder = start_recorder()
      targets = [X.target("a", recorder), X.target("b", recorder, :reference)]

      for seed <- 1..10 do
        reference = choices!(model, seed, "a", targets: targets)
        copied = choices!(model, seed, "b", targets: targets)

        assert Enum.map(copied, &{&1.root_id, &1.entry, doc!(&1)}) ==
                 Enum.map(reference, &{&1.root_id, &1.entry, doc!(&1)})
      end

      docs =
        for seed <- 1..10,
            choice <- choices!(model, seed, "b", targets: targets),
            do: doc!(choice)

      assert Enum.all?(docs, &(&1 in [@as_is, @two_steps]))
    end

    test "survives a carried choice realized again" do
      model = documented_model(Carried)
      report = failing_report!(model, shrink: false)
      traced = report.trace.expansion["solo"]
      assert Enum.any?(traced, &(&1.index == 1))

      carried = Expansion.carried(model, report.original_sequence, traced)

      assert Enum.map(carried.choices, &{&1.root_id, &1.index, doc!(&1)}) ==
               Enum.map(traced, &{&1.root_id, &1.index, doc!(&1)})

      assert @two_steps in Enum.map(carried.choices, &doc!/1)
    end

    test "of every choice in a shrunk report is the doc of the entry its commands realize" do
      model = documented_model(Shrunk)
      report = failing_report!(model, shrink: true)
      traced = report.trace.expansion["solo"]
      assert [_ | _] = traced

      for choice <- traced do
        modules = Enum.map(choice.commands, & &1.__struct__)

        expected =
          cond do
            choice.index == nil -> nil
            modules == [Authorize, Capture] -> @two_steps
            modules == [Pay] -> @as_is
          end

        assert doc!(choice) == expected
      end

      assert Enum.any?(traced, &(doc!(&1) == @two_steps))
    end
  end
end
