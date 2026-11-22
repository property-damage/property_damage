defmodule PropertyDamage.Next.JournalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Journal, ModelChangedError}
  alias PropertyDamage.Next.Test.Fixtures.{Probe, ProbeModel}
  alias PropertyDamage.Next.Test.Scheme

  alias PropertyDamage.Next.Test.Scheme.{
    CurrencyModel,
    HeavierPayModel,
    Model,
    NoRefundModel,
    ReorderedModel,
    WiderShareModel
  }

  alias PropertyDamage.Next.Test.Terms

  describe "saving and loading" do
    property "a saved and loaded journal rebuilds the identical plan" do
      check all(
              seed <- StreamData.integer(-1_000_000..1_000_000),
              max_steps <- StreamData.integer(1..25),
              max_runs: 60
            ) do
        plan = Next.plan(Model, seed, max_steps: max_steps)
        loaded = plan.journal |> Journal.to_binary() |> Journal.from_binary()

        assert loaded == plan.journal

        rebuilt = Next.plan(Model, loaded, max_steps: max_steps)
        assert rebuilt.steps == plan.steps
        assert rebuilt.withdrawn == plan.withdrawn
      end
    end

    test "a journal saves to a binary" do
      assert is_binary(Journal.to_binary(Next.plan(Model, 1, max_steps: 5).journal))
    end

    test "loading refuses a binary that is not a saved journal" do
      assert %{__exception__: true} = Terms.raised(fn -> Journal.from_binary("not a journal") end)

      not_a_journal = :erlang.term_to_binary(%{seed: 1, entries: %{}})
      assert %{__exception__: true} = Terms.raised(fn -> Journal.from_binary(not_a_journal) end)
    end
  end

  describe "the journal is the test case" do
    test "the journal of a plan built from a seed records that seed" do
      assert Next.plan(Model, 17, max_steps: 5).journal.seed == 17
    end

    test "the same seed builds the same plan, and seeds differ in what they build" do
      plans = for seed <- 1..20, do: Next.plan(Model, seed, max_steps: 10)

      assert Enum.map(1..20, &Next.plan(Model, &1, max_steps: 10)) == plans
      assert plans |> Enum.map(& &1.steps) |> Enum.uniq() |> length() > 1
    end

    test "an edited entry changes the rebuilt plan at its key and nowhere else" do
      plan = Next.plan(ProbeModel, 5, max_steps: 6)
      [first | rest] = plan.steps
      {{0, slot}, _, _} = key = {first.key, :command, :count}
      assert slot == 1

      other = if first.command.count == 7, do: 3, else: 7

      edited = %{
        plan.journal
        | entries: Map.put(plan.journal.entries, key, {:integer, other, 1..9})
      }

      [new_first | new_rest] = Next.plan(ProbeModel, edited, max_steps: 6).steps

      assert %Probe{count: ^other} = new_first.command
      assert new_first.command.size in other..(other + 3)
      assert new_first.command.color == first.command.color
      assert new_rest == rest
    end
  end

  describe "the model's fingerprint" do
    test "the journal carries the same fingerprint for every plan of one model" do
      assert Next.plan(Model, 1, max_steps: 5).journal.fingerprint ==
               Next.plan(Model, 2, max_steps: 5).journal.fingerprint
    end

    test "a journal replayed on a model with a changed spec list is refused" do
      journal = Next.plan(Model, 3, max_steps: 10).journal

      for changed <- [HeavierPayModel, ReorderedModel, CurrencyModel] do
        assert_raise ModelChangedError, fn -> Next.plan(changed, journal, max_steps: 10) end
      end
    end

    test "executing a journal on a changed model is refused before anything runs" do
      journal = Next.plan(Model, 3, max_steps: 10).journal

      assert_raise ModelChangedError, fn ->
        Next.replay(journal,
          model: HeavierPayModel,
          adapter: Scheme.Adapter,
          config: %{recorder: self()},
          max_steps: 10
        )
      end

      refute_received {:scheme_executed, _, _, _}
    end

    test "a changed when: function or a changed option value is not a changed spec list" do
      journal = Next.plan(Model, 3, max_steps: 10).journal

      assert %Next.Plan{} = Next.plan(NoRefundModel, journal, max_steps: 10)
      assert %Next.Plan{} = Next.plan(WiderShareModel, journal, max_steps: 10)
    end
  end
end
