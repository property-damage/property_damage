defmodule PropertyDamage.ExpansionShapeTest do
  # The shape of `expansions/0`: one `{Root, fun}` pair per root that has
  # expansions; `fun` returns a weighted list of command sequences, and the
  # identity is the received root struct alone in its sequence.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias Mix.Tasks.Pd.Validate
  alias PropertyDamage.Test.Expansion

  alias PropertyDamage.Test.Expansion.{
    Authorize,
    Authorized,
    Capture,
    Credit,
    Pay,
    Recorder
  }

  defp model!(name, opts), do: Expansion.define_model!(Module.concat(ExpansionA, name), opts)

  defp payment_model(name), do: model!(name, expansions: [{Pay, &Expansion.pay_expansions/2}])

  defp pair(recorder) do
    [Expansion.target("a", recorder), Expansion.target("b", recorder)]
  end

  # Splits `executed` into one slice per root: the root itself when it ran as
  # itself, or the authorization and capture of the payment example.
  defp slices([], []), do: []

  defp slices([%Pay{} = root | roots], [%Pay{} = ran | rest]) do
    assert ran == root
    [{:identity, root} | slices(roots, rest)]
  end

  defp slices([%Pay{amount: a} | roots], [%Authorize{amount: a}, %Capture{amount: a} | rest]),
    do: [{:rewrite, a} | slices(roots, rest)]

  describe "the payment example" do
    test "runs, and each variant realizes both entries" do
      recorder = start_recorder()
      model = payment_model(PaymentRuns)

      assert {:ok, stats} = Expansion.run(model, pair(recorder), max_runs: 10)

      entries = recorded(recorder)

      for name <- ["a", "b"] do
        counts = Expansion.expansion_counts(stats, name) |> Map.fetch!(Pay)
        assert counts["Pay[0]"] > 0
        assert counts["Pay[1]"] > 0

        # Every Capture received the id this variant's Authorize answered just
        # before it: the sibling's external() resolved per variant.
        captures =
          entries
          |> Expansion.answered(name)
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.filter(&match?([_, {%Capture{}, _}], &1))

        assert captures != []

        for [{%Authorize{amount: a}, [%Authorized{id: id}]}, {%Capture{} = capture, _}] <-
              captures do
          assert capture.authorization_id == id
          assert capture.amount == a
          assert String.starts_with?(id, name <> "-")
        end
      end
    end

    test "names its entries Pay[0] (the root) and Pay[1] (Authorize, Capture) in the counters" do
      recorder = start_recorder()
      model = payment_model(PaymentCounters)

      assert {:ok, stats} = Expansion.run(model, pair(recorder), max_runs: 10)

      for name <- ["a", "b"] do
        counts = Expansion.expansion_counts(stats, name)
        assert Map.keys(counts) == [Pay]
        pay = Map.fetch!(counts, Pay)

        assert pay |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort() == [
                 "Pay[0]",
                 "Pay[1]"
               ]

        assert Map.get(pay, :forced, 0) == 0
      end
    end

    test "the failure report names each root's entry and its leaves per variant" do
      recorder = start_recorder()
      model = payment_model(PaymentReport)

      targets = [
        Expansion.target("a", recorder, nil, %{fail: %{Capture => :error}}),
        Expansion.target("b", recorder)
      ]

      assert {:error, report} = Expansion.run(model, targets, max_runs: 10)

      expansions = Map.fetch!(report, :expansions)
      reference = Map.fetch!(expansions, "a")
      assert reference != []

      for element <- reference do
        assert {element.entry, element.leaves} in [
                 {"Pay[0]", [Pay]},
                 {"Pay[1]", [Authorize, Capture]}
               ]
      end

      failing = Enum.find(reference, &(&1.root == report.failed_at_index))
      assert failing.entry == "Pay[1]"
      assert failing.leaves == [Authorize, Capture]
      assert reference |> Enum.map(& &1.root) |> Enum.take(-1) == [report.failed_at_index]
    end
  end

  describe "the identity entry" do
    test "executes the root struct exactly as the generator drew it" do
      recorder = start_recorder()
      model = payment_model(IdentityStruct)

      targets = [
        Expansion.target("ref", recorder, :identity),
        Expansion.target("b", recorder, :random)
      ]

      assert {:ok, _stats} = Expansion.run(model, targets, max_runs: 3, max_commands: 4)

      roots = Enum.flat_map(0..2, &Expansion.roots(model, 4_242, &1, 4))
      entries = recorded(recorder)

      # The :identity variant executed the roots themselves.
      assert Expansion.executed(entries, "ref") == roots

      # Where "b" drew the identity it executed the same struct.
      kinds = roots |> slices(Expansion.executed(entries, "b")) |> Enum.map(&elem(&1, 0))
      assert :identity in kinds
      assert :rewrite in kinds
    end
  end

  describe "structs in a sequence" do
    test "a struct other than the received root is a generation error before any setup" do
      recorder = start_recorder()

      model =
        model!(ForeignStruct, expansions: [{Pay, fn _pay, _state -> [[%Pay{amount: 99}]] end}])

      message =
        Expansion.error_message(fn -> Expansion.run(model, [Expansion.target("a", recorder)]) end)

      assert message =~ "Pay[0]"
      assert message =~ ~r/(position|leaf) 0/
      assert Expansion.setups(recorder) == 0
    end

    test "the received root beside another leaf is a generation error before any setup" do
      recorder = start_recorder()

      model =
        model!(RootBesideLeaf,
          expansions: [
            {Pay, fn pay, _state -> [[{Credit, overrides: %{amount: 0}}, pay]] end}
          ]
        )

      message =
        Expansion.error_message(fn -> Expansion.run(model, [Expansion.target("a", recorder)]) end)

      assert message =~ "Pay[0]"
      assert message =~ ~r/(position|leaf) 1/
      assert Expansion.setups(recorder) == 0
    end
  end

  describe "when: and weight: inside a sequence" do
    defp sequence_option_model(name, key) do
      option =
        case key do
          :when -> [when: fn _state -> false end]
          :weight -> [weight: 5]
        end

      model!(name,
        expansions: [
          {Pay,
           fn %Pay{amount: a}, _state ->
             [[{Credit, option ++ [overrides: %{amount: a}]}]]
           end}
        ]
      )
    end

    test "are accepted and ignored by a run" do
      for {key, name} <- [when: WhenRuns, weight: WeightRuns] do
        recorder = start_recorder()
        model = sequence_option_model(name, key)

        assert {:ok, _stats} = Expansion.run(model, [Expansion.target("a", recorder)])

        # The `when:` that never holds was ignored: every root ran as a Credit.
        executed = Expansion.executed(recorded(recorder), "a")
        assert executed != []
        assert Enum.all?(executed, &match?(%Credit{}, &1))
      end
    end

    test "are warned on by mix pd.validate --seeds, naming the root, the entry and the key" do
      for {key, name} <- [when: WhenWarned, weight: WeightWarned] do
        model = sequence_option_model(name, key)

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

        assert output =~ "ignored in a sequence"
        assert output =~ "Pay[0]"
        assert output =~ "#{key}"
      end
    end
  end

  describe "entry weights" do
    test "a weight of 0, a negative weight or a non-integer weight is an error naming the root and weight:" do
      for {weight, name} <- [{0, ZeroWeight}, {-1, NegativeWeight}, {1.5, FloatWeight}] do
        recorder = start_recorder()

        model =
          model!(name, expansions: [{Pay, fn pay, _state -> [{[pay], weight: weight}] end}])

        message =
          Expansion.error_message(fn ->
            Expansion.run(model, [Expansion.target("a", recorder)])
          end)

        assert message =~ "weight:"
        assert message =~ "Pay"
      end
    end
  end

  describe "a root listed twice" do
    test "is a load error naming it, before any setup and in Validation.validate!/3" do
      recorder = start_recorder()
      fun = &Expansion.pay_expansions/2
      model = model!(ListedTwice, expansions: [{Pay, fun}, {Pay, fun}])

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, [Expansion.target("a", recorder)], validate: true)
        end)

      assert message =~ "expansions"
      assert message =~ inspect(Pay)
      assert Expansion.setups(recorder) == 0

      message =
        Expansion.error_message(fn -> PropertyDamage.Validation.validate!(model, Recorder) end)

      assert message =~ "expansions"
      assert message =~ inspect(Pay)
    end
  end

  describe "the types and callbacks on PropertyDamage.Model" do
    defp type_strings do
      {:ok, types} = Code.Typespec.fetch_types(PropertyDamage.Model)

      for {kind, {name, _ast, args} = type} <- types,
          kind in [:type, :opaque, :typep],
          into: %{} do
        {{name, length(args)}, type |> Code.Typespec.type_to_quoted() |> Macro.to_string()}
      end
    end

    defp callback_strings do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(PropertyDamage.Model)

      for {{name, arity}, [spec | _]} <- callbacks, into: %{} do
        {{name, arity}, name |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()}
      end
    end

    test "declares command_spec, sequence, identity and choices(item)" do
      types = type_strings()

      for key <- [{:command_spec, 0}, {:sequence, 0}, {:identity, 0}, {:choices, 1}] do
        assert Map.has_key?(types, key), "missing @type #{inspect(key)}"
      end

      command_spec = Map.fetch!(types, {:command_spec, 0})
      refute command_spec =~ "pos_integer"
      assert command_spec =~ "command_opts()"
      assert Map.fetch!(types, {:sequence, 0}) =~ "[command_spec()]"
    end

    test "types commands/0, setup_each/0, teardown_each/0 and expansions/0 with them" do
      callbacks = callback_strings()

      assert Map.fetch!(callbacks, {:commands, 0}) =~ "choices(command_spec())"
      assert Map.fetch!(callbacks, {:setup_each, 0}) =~ "sequence()"
      assert Map.fetch!(callbacks, {:teardown_each, 0}) =~ "sequence()"

      expansions = Map.fetch!(callbacks, {:expansions, 0})
      assert expansions =~ "choices("
      assert expansions =~ "sequence()"
      assert expansions =~ "identity()"
    end

    test "expansions/0 is optional" do
      assert {:expansions, 0} in PropertyDamage.Model.behaviour_info(:optional_callbacks)
    end

    test "the first sentence of the expansions/0 doc states the equivalence contract" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(PropertyDamage.Model)

      doc =
        Enum.find_value(docs, fn
          {{:callback, :expansions, 0}, _, _, %{"en" => doc}, _} -> doc
          _other -> nil
        end)

      assert is_binary(doc), "expansions/0 has no doc"

      first =
        doc
        |> String.replace(~r/\s+/, " ")
        |> String.split(~r/(?<=\.)\s/, parts: 2)
        |> hd()
        |> String.downcase()

      assert first =~ "every expansion"
      assert first =~ "same as the root"
      assert first =~ "done"
      assert first =~ "@compare"
    end
  end
end
