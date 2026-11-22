defmodule PropertyDamage.Next.JournalV2Test do
  # The saved journal's format version 2: the entry of a StreamData value
  # holds its path, a slot can hold an empty pick, and the journal records no
  # origin. A replay runs on the model that saved the journal: it refuses a
  # changed spec list and says nothing about a changed generator.
  use ExUnit.Case, async: true

  import PropertyDamage.Next.Test.OwnLog, only: [with_own_log: 1]

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Journal, ModelChangedError}
  alias PropertyDamage.Next.Test.Scheme.{Adapter, HeavierPayModel, Model, WiderShareModel}

  @format :property_damage_next_journal

  test "a binary saved in format version 1 is refused, naming versions 1 and 2" do
    v1 =
      :erlang.term_to_binary(
        {@format, 1, %{seed: 1, max_steps: 1, entries: %{}, fingerprint: nil}}
      )

    error = assert_raise ArgumentError, fn -> Journal.from_binary(v1) end
    assert error.message =~ "version 1"
    assert error.message =~ "version 2"
  end

  test "a saved journal is format version 2 and holds the seed, the slots, the entries and the fingerprint only" do
    journal = Next.plan(Model, 3, max_steps: 8).journal

    assert {@format, 2, content} = journal |> Journal.to_binary() |> :erlang.binary_to_term()
    assert content |> Map.keys() |> Enum.sort() == [:entries, :fingerprint, :max_steps, :seed]
    assert content.entries == journal.entries
  end

  test "a replay on a changed spec list is refused before the adapter runs" do
    journal = Next.plan(Model, 3, max_steps: 10).journal

    assert_raise ModelChangedError, fn ->
      Next.replay(journal, model: HeavierPayModel, adapter: Adapter, config: %{recorder: self()})
    end

    refute_received {:scheme_executed, _, _, _}
  end

  test "a replay on a changed generator runs and says nothing" do
    for seed <- 1..5 do
      journal = Next.plan(Model, seed, max_steps: 10).journal

      {result, log} =
        with_own_log(fn ->
          Next.replay(journal,
            model: WiderShareModel,
            adapter: Adapter,
            config: %{fault: :skip_credit}
          )
        end)

      assert match?({:ok, _}, result) or match?({:error, %Next.Failure{}}, result)
      assert log == ""
    end
  end
end
