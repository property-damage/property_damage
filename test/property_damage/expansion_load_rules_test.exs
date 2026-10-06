defmodule PropertyDamage.ExpansionLoadRulesTest do
  # Rules checked when a run starts, before any target is set up: a model
  # with expansions compares at the end, lists only roots that are commands
  # and not probes, and does not branch.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.Test.Expansion

  alias PropertyDamage.Test.Expansion.{
    Credit,
    Ledger,
    LedgerAtPay,
    LedgerAtPayEnd,
    Look,
    Pay,
    Recorder
  }

  defp model!(name, opts), do: Expansion.define_model!(Module.concat(ExpansionA, name), opts)

  defp expansions, do: [{Pay, &Expansion.pay_expansions/2}]

  defp one(recorder), do: [Expansion.target("a", recorder)]
  defp two(recorder), do: [Expansion.target("a", recorder), Expansion.target("b", recorder)]

  describe "a model with expansions compares at the final boundary" do
    test "only @compare every: Pay is an error naming expansions/0 and @compare every: :end" do
      model = model!(ComparesAtPay, expansions: expansions(), checks: [LedgerAtPay])

      for targets <- [&two/1, &one/1] do
        recorder = start_recorder()

        message =
          Expansion.error_message(fn ->
            Expansion.run(model, targets.(recorder), validate: true)
          end)

        assert message =~ "expansions/0"
        assert message =~ "@compare every: :end"
        assert Expansion.setups(recorder) == 0
      end
    end

    test "every: 1 and every: [Pay, :end] pass" do
      for {name, checks} <- [{ComparesEvery, [Ledger]}, {ComparesAtEnd, [LedgerAtPayEnd]}] do
        model = model!(name, expansions: expansions(), checks: checks)
        recorder = start_recorder()

        assert {:ok, _stats} = Expansion.run(model, two(recorder), validate: true)
        assert {:ok, _stats} = Expansion.run(model, one(recorder), validate: true)
      end
    end

    test "two or more targets and no @compare at all is still the error naming @compare" do
      model = model!(NoCompare, checks: [])
      recorder = start_recorder()

      message = Expansion.error_message(fn -> Expansion.run(model, two(recorder)) end)

      assert message =~ "@compare"
      assert Expansion.setups(recorder) == 0
    end
  end

  describe "the keys of expansions/0" do
    test "a module that is not in commands/0 is a load error naming it" do
      expansions = [{Credit, fn credit, _state -> [[credit]] end}]
      model = model!(NotARoot, expansions: expansions)
      recorder = start_recorder()

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, one(recorder), validate: true)
        end)

      assert message =~ inspect(Credit)
      assert Expansion.setups(recorder) == 0

      message =
        Expansion.error_message(fn -> PropertyDamage.Validation.validate!(model, Recorder) end)

      assert message =~ inspect(Credit)
    end

    test "a probe root is a load error" do
      model =
        model!(ProbeRoot,
          commands: [Pay, Look],
          expansions: [{Look, fn look, _state -> [[look]] end}]
        )

      recorder = start_recorder()

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, one(recorder), validate: true)
        end)

      assert message =~ inspect(Look)
      assert message =~ "probe"
      assert Expansion.setups(recorder) == 0
    end
  end

  describe "branching" do
    test "with a model defining expansions/0 is an option error naming both" do
      model = model!(Branches, expansions: expansions())
      recorder = start_recorder()

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, one(recorder), branching: [], max_commands: 8)
        end)

      assert message =~ "branching"
      assert message =~ "expansions/0"
      assert Expansion.setups(recorder) == 0
    end

    test "with a model without expansions/0 still runs on one target" do
      model = model!(BranchesPlain, [])
      recorder = start_recorder()

      assert {:ok, _stats} =
               Expansion.run(model, one(recorder),
                 branching: [branch_probability: 1.0, min_prefix_length: 1],
                 max_commands: 8
               )

      assert Expansion.setups(recorder) == 1
    end
  end
end
