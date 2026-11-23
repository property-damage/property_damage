defmodule PropertyDamage.Next.PathJournalTest do
  # The path of each step is drawn into the journal: the pick under
  # `{step, :path}`, and each draw of a path's own generators under
  # `{step, :path, name}`. A step whose command module is not listed draws
  # nothing more, and every other entry is drawn as it is for the same
  # model without paths. The step records its path as `{index, commands}`.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Journal

  alias PropertyDamage.Next.Test.Paths.{
    AssignModel,
    AssignPlainModel,
    Pay,
    Peek,
    PlainModel,
    Recorded,
    Refund,
    Settle,
    SettleModel,
    SplitModel
  }

  @max_steps 8
  @seeds 1..12

  defp path_key?({_step, :path}), do: true
  defp path_key?({_step, :path, _name}), do: true
  defp path_key?(_key), do: false

  defp path_keys(journal, step_key) do
    journal.entries |> Map.keys() |> Enum.filter(&(path_key?(&1) and elem(&1, 0) == step_key))
  end

  defp plans(model), do: Enum.map(@seeds, &Next.plan(model, &1, max_steps: @max_steps))

  test "the pick of each listed step is a member entry under {step, :path} holding its index" do
    picks =
      for plan <- plans(SplitModel), step <- plan.steps do
        assert {index, [_ | _]} = Recorded.path(step)
        assert plan.journal.entries[{step.key, :path}] == {:member, index, index}
        index
      end

    assert 0 in picks
    assert 1 in picks
  end

  test "the plain path is the step's command alone" do
    plain =
      for plan <- plans(SplitModel), step <- plan.steps, Recorded.pick(step) == 0 do
        assert Recorded.path(step) == {0, [step.command]}
      end

    assert plain != []
  end

  test "a payment's second path is the payment followed by a read" do
    second =
      for plan <- plans(SplitModel),
          %{command: %Pay{}} = step <- plan.steps,
          Recorded.pick(step) == 1 do
        assert Recorded.path(step) == {1, [step.command, %Peek{}]}
      end

    assert second != []
  end

  test "a path that draws a value writes it under {step, :path, name} and builds its commands from it" do
    split =
      for plan <- plans(SplitModel),
          %{command: %Refund{amount: amount} = refund} = step <- plan.steps,
          Recorded.pick(step) == 1 do
        assert {:integer, first, range} = plan.journal.entries[{step.key, :path, :first}]
        assert range == 1..(amount - 1)

        assert Recorded.path(step) ==
                 {1, [%{refund | amount: first}, %{refund | amount: amount - first}]}

        assert path_keys(plan.journal, step.key) |> Enum.sort() == [
                 {step.key, :path},
                 {step.key, :path, :first}
               ]

        step
      end

    assert split != []
  end

  test "a path that draws nothing writes only the pick" do
    plain =
      for plan <- plans(SplitModel),
          step <- plan.steps,
          Recorded.pick(step) == 0 or match?(%Pay{}, step.command) do
        assert path_keys(plan.journal, step.key) == [{step.key, :path}]
      end

    assert plain != []
  end

  test "a step whose module is not listed has no path and no path entry" do
    settled =
      for plan <- plans(SettleModel), %{command: %Settle{}} = step <- plan.steps do
        assert Recorded.path(step) == nil
        assert path_keys(plan.journal, step.key) == []
        step
      end

    assert settled != []
  end

  test "a model without paths has steps without a path and a journal without path entries" do
    for plan <- plans(PlainModel) do
      assert Enum.all?(plan.steps, &(Recorded.path(&1) == nil))
      refute plan.journal.entries |> Map.keys() |> Enum.any?(&path_key?/1)
    end
  end

  describe "on the same seed, the model with paths and the same model without them" do
    for {with_paths, without} <- [{SplitModel, PlainModel}, {AssignModel, AssignPlainModel}] do
      test "#{inspect(with_paths)} draws every other entry as #{inspect(without)} does" do
        for seed <- @seeds do
          listed = Next.plan(unquote(with_paths), seed, max_steps: @max_steps)
          plain = Next.plan(unquote(without), seed, max_steps: @max_steps)

          kept = Map.reject(listed.journal.entries, fn {key, _entry} -> path_key?(key) end)
          assert kept == plain.journal.entries
          assert listed.journal.seed == plain.journal.seed
          assert listed.journal.max_steps == plain.journal.max_steps
          assert listed.journal.fingerprint == plain.journal.fingerprint

          assert Enum.map(listed.steps, &Map.put(&1, :path, nil)) ==
                   Enum.map(plain.steps, &Map.put(&1, :path, nil))
        end
      end
    end
  end

  test "a journal with paths saves, loads and rebuilds the same plan, paths included" do
    assert Enum.any?(plans(SplitModel), fn plan ->
             Enum.any?(plan.steps, &(Recorded.pick(&1) == 1))
           end)

    for plan <- plans(SplitModel) do
      binary = Journal.to_binary(plan.journal)
      assert {:property_damage_next_journal, 3, _content} = :erlang.binary_to_term(binary)

      loaded = Journal.from_binary(binary, model: SplitModel)
      assert loaded == plan.journal

      rebuilt = Next.plan(SplitModel, loaded)
      assert rebuilt.steps == plan.steps
      assert rebuilt.journal == plan.journal
    end
  end
end
