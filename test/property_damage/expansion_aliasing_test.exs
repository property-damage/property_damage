defmodule PropertyDamage.ExpansionAliasingTest do
  # Placeholders across leaves and roots. A leaf's arity-2 `overrides:` sees
  # the earlier leaves of its sequence with their simulated events, so it can
  # take a sibling's `external()` value. A placeholder the root's simulation
  # minted resolves, in a variant that ran a rewrite, from the one leaf that
  # produces the same event at the same field.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias PropertyDamage.Placeholder
  alias PropertyDamage.Test.Expansion

  alias PropertyDamage.Test.Expansion.{
    Authorize,
    Authorized,
    Capture,
    Confirm,
    Open,
    Opened,
    Pay,
    Recorder,
    Reserve,
    Use,
    Used
  }

  defp model!(name, opts), do: Expansion.define_model!(Module.concat(ExpansionA, name), opts)

  # One Open root, then Use roots that consume the account it opened.
  defp account_model(name, rewrite) do
    model!(name,
      commands: [
        {Open, when: &(&1.accounts == [])},
        {Use, when: &(&1.accounts != []), overrides: &%{account_id: List.last(&1.accounts)}}
      ],
      expansions: [{Open, fn _open, _state -> [rewrite] end}]
    )
  end

  describe "the arity-2 overrides:" do
    test "sees the earlier leaves with their simulated events, and resolves their ids per variant" do
      test_pid = self()

      model =
        model!(PriorLeaves,
          expansions: [
            {Pay,
             fn %Pay{amount: a}, _state ->
               [
                 [
                   {Authorize, overrides: %{amount: a}},
                   {Capture,
                    overrides: fn _state, prior_leaves ->
                      send(test_pid, {:prior_leaves, prior_leaves})
                      [%{events: [%Authorized{id: id}]}] = prior_leaves
                      %{authorization_id: id, amount: a}
                    end}
                 ]
               ]
             end}
          ]
        )

      recorder = start_recorder()
      targets = [Expansion.target("a", recorder), Expansion.target("b", recorder)]
      assert {:ok, _stats} = Expansion.run(model, targets, max_commands: 3)

      assert_receive {:prior_leaves, prior_leaves}, 1_000

      assert [%{command: %Authorize{} = authorize, events: [%Authorized{} = authorized]} = leaf] =
               prior_leaves

      assert Map.keys(leaf) |> Enum.sort() == [:command, :events]
      assert authorized.amount == authorize.amount
      assert %Placeholder{} = authorized.id

      entries = recorded(recorder)

      for name <- ["a", "b"] do
        pairs = Expansion.answered(entries, name)
        assert pairs != []

        for [{%Authorize{}, [%Authorized{id: id}]}, {%Capture{} = capture, _}] <-
              Enum.chunk_every(pairs, 2, 2, :discard) do
          assert capture.authorization_id == id
          assert String.starts_with?(id, name <> "-")
        end
      end
    end

    test "in commands/0 is a load error naming the command, before any setup" do
      capture = {Capture, overrides: fn _state, _prior -> %{} end}
      model = model!(ArityTwoRoot, commands: [Pay, capture])
      recorder = start_recorder()

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, [Expansion.target("a", recorder)], validate: true)
        end)

      assert message =~ inspect(Capture)
      assert message =~ "expansion sequence"
      assert Expansion.setups(recorder) == 0

      message =
        Expansion.error_message(fn -> PropertyDamage.Validation.validate!(model, Recorder) end)

      assert message =~ inspect(Capture)
      assert message =~ "expansion sequence"
    end

    test "in setup_each/0 is a load error naming the command, before any setup" do
      capture = {Capture, overrides: fn _state, _prior -> %{} end}
      model = model!(ArityTwoSetup, setup: [capture])
      recorder = start_recorder()

      message =
        Expansion.error_message(fn ->
          Expansion.run(model, [Expansion.target("a", recorder)], validate: true)
        end)

      assert message =~ inspect(Capture)
      assert message =~ "expansion sequence"
      assert Expansion.setups(recorder) == 0

      message =
        Expansion.error_message(fn -> PropertyDamage.Validation.validate!(model, Recorder) end)

      assert message =~ inspect(Capture)
      assert message =~ "expansion sequence"
    end
  end

  describe "a root's placeholder in a variant that ran a rewrite" do
    test "resolves from the leaf that produced the same event" do
      model = account_model(Aliased, [Reserve, Confirm])
      recorder = start_recorder()

      targets = [
        Expansion.target("a", recorder, :identity),
        Expansion.target("b", recorder, :random)
      ]

      assert {:ok, _stats} = Expansion.run(model, targets, max_runs: 2, max_commands: 4)

      entries = recorded(recorder)

      # "a" ran Open itself; "b" ran Reserve then Confirm in its place.
      assert [%Open{} | a_rest] = Expansion.executed(entries, "a")
      assert [%Reserve{}, %Confirm{} | _] = Expansion.executed(entries, "b")
      assert Enum.any?(a_rest, &match?(%Use{}, &1))

      for name <- ["a", "b"] do
        answered = Expansion.answered(entries, name)
        opened = for {_command, [%Opened{id: id}]} <- answered, do: id
        uses = for {%Use{account_id: id}, [%Used{}]} <- answered, do: id

        assert opened != []
        assert uses != []
        # Each Use received an id this variant's own Open or Confirm answered.
        assert Enum.all?(uses, &(&1 in opened))
        assert Enum.all?(uses, &String.starts_with?(&1, name <> "-open"))
      end
    end
  end

  describe "a root's placeholder with no single producing leaf" do
    test "zero candidate leaves is a generation error naming the root, entry, field and candidates" do
      model = account_model(NoCandidate, [Reserve])
      recorder = start_recorder()

      targets = [
        Expansion.target("a", recorder, :identity),
        Expansion.target("b", recorder, :random)
      ]

      message = Expansion.error_message(fn -> Expansion.run(model, targets) end)

      assert message =~ "Open[0]"
      assert message =~ ~r/:id\b|\bid\b/
      assert Expansion.setups(recorder) == 0
    end

    test "several candidate leaves is a generation error naming the root, entry, field and candidates" do
      model = account_model(TwoCandidates, [Confirm, Confirm])
      recorder = start_recorder()

      targets = [
        Expansion.target("a", recorder, :identity),
        Expansion.target("b", recorder, :random)
      ]

      message = Expansion.error_message(fn -> Expansion.run(model, targets) end)

      assert message =~ "Open[0]"
      assert message =~ ~r/:id\b|\bid\b/
      assert message =~ "Confirm"
      assert Expansion.setups(recorder) == 0
    end
  end
end
