defmodule PropertyDamage.ExpansionWitnessTest do
  # One configuration that uses every part of expansions at once: a root with
  # three entries (the root itself, a two-leaf rewrite, and a three-leaf
  # rewrite whose second leaf takes its sibling's `external()` id), a
  # reference and a second variant that each draw their own expansions, and
  # a third variant that copies the reference.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias PropertyDamage.Test.Expansion
  alias PropertyDamage.Test.Expansion.{Authorize, Authorized, Capture, Credit, Pay}

  @entries ["Pay[0]", "Pay[1]", "Pay[2]"]

  test "three variants over 50 runs: green, every entry drawn, the copy leaf for leaf" do
    model =
      Expansion.define_model!(ExpansionA.Witness,
        expansions: [{Pay, &Expansion.three_way_expansions/2}]
      )

    recorder = start_recorder()

    targets = [
      Expansion.target("reference", recorder, :random),
      Expansion.target("second", recorder, :random),
      Expansion.target("copy", recorder, :reference)
    ]

    assert {:ok, stats} = Expansion.run(model, targets, max_runs: 50, max_commands: 3)

    for name <- ["reference", "second"] do
      counts = stats |> Expansion.expansion_counts(name) |> Map.fetch!(Pay)

      for entry <- @entries do
        assert Map.get(counts, entry, 0) > 0, "#{name} never drew #{entry}"
      end

      assert Map.get(counts, :forced, 0) == 0
    end

    entries = recorded(recorder)
    reference = Expansion.executed(entries, "reference")
    copy = Expansion.executed(entries, "copy")

    # Every leaf kind ran in the reference, and the copy ran it leaf for leaf.
    for module <- [Pay, Credit, Authorize, Capture] do
      assert Enum.any?(reference, &is_struct(&1, module))
    end

    assert Enum.map(copy, &Expansion.without_ids/1) ==
             Enum.map(reference, &Expansion.without_ids/1)

    # Each variant's Capture holds the id its own Authorize answered.
    for name <- ["reference", "second", "copy"] do
      for [{%Authorize{}, [%Authorized{id: id}]}, {%Capture{authorization_id: captured}, _}] <-
            entries |> Expansion.answered(name) |> Enum.chunk_every(2, 1, :discard) do
        assert captured == id
        assert String.starts_with?(id, name <> "-")
      end
    end
  end
end
