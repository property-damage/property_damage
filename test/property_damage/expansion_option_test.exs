defmodule PropertyDamage.ExpansionOptionTest do
  # The `expansion:` target option: `:random` (the default), `:identity` or
  # `:reference`. The first target is the reference and cannot copy itself.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias PropertyDamage.{Options, Target}
  alias PropertyDamage.Test.Expansion
  alias PropertyDamage.Test.Expansion.{Pay, Recorder}

  defp model!(name, opts), do: Expansion.define_model!(Module.concat(ExpansionA, name), opts)

  defp payment_model(name), do: model!(name, expansions: [{Pay, &Expansion.pay_expansions/2}])

  describe "the expansion: target option" do
    test "accepts :random, :identity and :reference" do
      for value <- [:random, :identity, :reference] do
        assert {:ok, [_reference, target]} =
                 Options.validate_targets([Recorder, {Recorder, name: "b", expansion: value}])

        assert Map.fetch!(target, :expansion) == value
      end
    end

    test "rejects a fourth value with a message naming the three" do
      for value <- [:drawn, :all] do
        assert {:error, message} =
                 Options.validate_targets([Recorder, {Recorder, name: "b", expansion: value}])

        assert message =~ ":random"
        assert message =~ ":identity"
        assert message =~ ":reference"
      end
    end

    test "defaults to :random on every target" do
      assert {:ok, targets} = Options.validate_targets([Recorder, {Recorder, name: "b"}])
      assert Enum.map(targets, &Map.fetch!(&1, :expansion)) == [:random, :random]
    end

    test "round-trips through Target.to_entry/1" do
      for value <- [:random, :identity, :reference] do
        {:ok, [_reference, target]} =
          Options.validate_targets([Recorder, {Recorder, name: "b", expansion: value}])

        {_adapter, kw} = entry = Target.to_entry(target)
        assert Keyword.fetch!(kw, :expansion) == value

        assert {:ok, [_, again]} = Options.validate_targets([Recorder, entry])
        assert again == %{target | index: 1}
      end
    end
  end

  describe "the reference cannot copy itself" do
    test ":reference on the first of two targets is an error before any setup" do
      recorder = start_recorder()
      model = payment_model(ReferenceFirst)

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, [
            Expansion.target("a", recorder, :reference),
            Expansion.target("b", recorder)
          ])
        end)

      assert message =~ "reference"
      assert message =~ "cannot copy"
      assert Expansion.setups(recorder) == 0
    end

    test ":reference on the sole target of a one-target run is the same error" do
      recorder = start_recorder()
      model = payment_model(ReferenceSole)

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, [Expansion.target("a", recorder, :reference)])
        end)

      assert message =~ "reference"
      assert message =~ "cannot copy"
      assert Expansion.setups(recorder) == 0
    end
  end

  describe "mixing values across targets" do
    test "the three values on three targets run, the third copying the reference" do
      recorder = start_recorder()
      model = payment_model(ThreeValues)

      targets = [
        Expansion.target("a", recorder, :random),
        Expansion.target("b", recorder, :identity),
        Expansion.target("c", recorder, :reference)
      ]

      assert {:ok, _stats} = Expansion.run(model, targets, max_runs: 5)

      entries = recorded(recorder)
      a = Expansion.executed(entries, "a")
      b = Expansion.executed(entries, "b")
      c = Expansion.executed(entries, "c")

      # "a" rewrote at least one root; "b" ran only roots; "c" copied "a".
      assert Enum.any?(a, &(not match?(%Pay{}, &1)))
      assert Enum.all?(b, &match?(%Pay{}, &1))
      assert Enum.map(c, &Expansion.without_ids/1) == Enum.map(a, &Expansion.without_ids/1)
    end

    test "a model without expansions/0 accepts every value, and every variant runs the roots" do
      recorder = start_recorder()
      model = model!(NoExpansions, [])

      targets = [
        Expansion.target("a", recorder, :random),
        Expansion.target("b", recorder, :identity),
        Expansion.target("c", recorder, :reference)
      ]

      assert {:ok, _stats} = Expansion.run(model, targets, max_runs: 3)

      sequences = Expansion.sequences(recorder, ["a", "b", "c"])
      assert sequences["a"] != []
      assert sequences["b"] == sequences["a"]
      assert sequences["c"] == sequences["a"]
    end
  end
end
