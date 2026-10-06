defmodule PropertyDamage.ExpansionDrawTest do
  # The per-variant draw: a `:random` variant draws its entry at each root
  # from the seed, the run, its own name and the root index; `:identity` runs
  # the roots; `:reference` copies the reference leaf for leaf. A leaf that
  # fails its precondition withdraws its entry; when no entry remains the root
  # runs as itself, counted as "identity, forced".
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport,
    only: [start_recorder: 0, recorded: 1, take_messages: 1]

  alias PropertyDamage.Test.Expansion

  alias PropertyDamage.Test.Expansion.{
    Arm,
    Authorize,
    Blocked,
    Capture,
    Credit,
    Fire,
    Pay,
    Skip,
    Stuck
  }

  # Seeds the bounded searches below try, in order.
  @search 1..30

  defp model!(name, opts), do: Expansion.define_model!(Module.concat(ExpansionA, name), opts)

  defp payment_model(name), do: model!(name, expansions: [{Pay, &Expansion.pay_expansions/2}])

  # The sequences each named target executed in one run of `model`.
  defp sequences(model, specs, extra \\ []) do
    recorder = start_recorder()
    targets = for {name, value} <- specs, do: Expansion.target(name, recorder, value)

    assert {:ok, _stats} =
             Expansion.run(model, targets, Keyword.merge([max_runs: 3, max_commands: 5], extra))

    Expansion.sequences(recorder, Enum.map(specs, &elem(&1, 0)))
  end

  defp rewrote?(commands), do: Enum.any?(commands, &(not match?(%Pay{}, &1)))

  # The first seed of @search for which `property` holds, or nil.
  defp search(property), do: Enum.find(@search, property)

  describe "the draw is a function of the seed, the run and the variant name" do
    test "two runs with the same seed and names execute the same sequences" do
      model = payment_model(SameSeed)
      specs = [{"a", nil}, {"b", nil}]

      first = sequences(model, specs)
      assert rewrote?(first["a"])
      assert rewrote?(first["b"])
      assert sequences(model, specs) == first

      # A fresh compile of the same model draws the same.
      fresh = payment_model(SameSeedFresh)
      assert sequences(fresh, specs) == first
    end

    @tag timeout: 180_000
    test "a new OS process executes the same sequences" do
      here = Expansion.static_sequences(77)
      assert rewrote?(here["a"])

      code = """
      IO.puts("SEQUENCES:" <> Base.encode64(:erlang.term_to_binary(
        PropertyDamage.Test.Expansion.static_sequences(77))))
      """

      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
          cd: File.cwd!(),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      [_, encoded] = Regex.run(~r/SEQUENCES:(\S+)/, output)
      assert :erlang.binary_to_term(Base.decode64!(encoded)) == here
    end

    test "reordering targets keeps every named :random variant's sequence" do
      model = payment_model(Reorder)

      first = sequences(model, [{"a", :random}, {"b", :random}, {"c", :random}])
      again = sequences(model, [{"c", :random}, {"a", :random}, {"b", :random}])

      assert rewrote?(first["b"])

      for name <- ["a", "b", "c"] do
        assert again[name] == first[name], "#{name} changed when the targets were reordered"
      end
    end

    test "renaming the second variant re-draws its sequence and keeps the reference's" do
      model = payment_model(Rename)

      seed =
        search(fn seed ->
          before = sequences(model, [{"a", nil}, {"b", nil}], seed: seed, max_runs: 1)
          renamed = sequences(model, [{"a", nil}, {"b2", nil}], seed: seed, max_runs: 1)
          before["b"] != renamed["b2"]
        end)

      assert seed, "no seed in #{inspect(@search)} where renaming re-draws"

      before = sequences(model, [{"a", nil}, {"b", nil}], seed: seed, max_runs: 1)
      renamed = sequences(model, [{"a", nil}, {"b2", nil}], seed: seed, max_runs: 1)
      assert renamed["a"] == before["a"]
      assert renamed["b2"] != before["b"]
    end

    test "two :random variants draw independently" do
      model = payment_model(Independent)

      seed =
        search(fn seed ->
          run = sequences(model, [{"a", :random}, {"b", :random}], seed: seed, max_runs: 1)
          run["a"] != run["b"]
        end)

      assert seed, "no seed in #{inspect(@search)} where two :random variants differ"

      run = sequences(model, [{"a", :random}, {"b", :random}], seed: seed, max_runs: 1)
      assert run["a"] != run["b"]
      assert rewrote?(run["a"]) or rewrote?(run["b"])
    end
  end

  describe ":identity and :reference variants" do
    test "an :identity variant executes exactly the roots" do
      model = payment_model(IdentityRoots)
      run = sequences(model, [{"a", :random}, {"b", :identity}], max_runs: 3, max_commands: 5)

      roots = Enum.flat_map(0..2, &Expansion.roots(model, 4_242, &1, 5))
      assert run["b"] == roots
      assert rewrote?(run["a"])
    end

    test "a :reference variant executes the reference's commands leaf for leaf" do
      model = payment_model(ReferenceCopy)
      recorder = start_recorder()

      targets = [
        Expansion.target("a", recorder, :random),
        Expansion.target("b", recorder, :reference)
      ]

      assert {:ok, _stats} = Expansion.run(model, targets, max_runs: 5, max_commands: 5)

      entries = recorded(recorder)
      a = Expansion.executed(entries, "a")
      b = Expansion.executed(entries, "b")

      assert rewrote?(a)
      assert Enum.map(b, &Expansion.without_ids/1) == Enum.map(a, &Expansion.without_ids/1)

      # The placeholders resolved per variant: each Capture holds its own
      # variant's authorization id.
      for {name, commands} <- [{"a", a}, {"b", b}], %Capture{authorization_id: id} <- commands do
        assert String.starts_with?(id, name <> "-")
      end
    end
  end

  describe "a leaf that fails its precondition" do
    # Entry 0 holds a Blocked leaf, whose commands/0 `when:` never holds.
    # Entry 2's Fire is allowed only once Arm ran: its precondition holds at
    # its own position in the variant's state, not at the root's.
    defp withdrawal_model(name) do
      model!(name,
        commands: [Pay, {Blocked, when: fn _state -> false end}, {Fire, when: & &1.armed}],
        expansions: [
          {Pay,
           fn %Pay{amount: a} = pay, _state ->
             [
               {[{Blocked, overrides: %{amount: a}}], weight: 50},
               [pay],
               [Arm, {Fire, overrides: %{amount: a}}]
             ]
           end}
        ]
      )
    end

    test "withdraws its entry; the draw repeats among the rest, deterministically" do
      model = withdrawal_model(Withdrawal)
      recorder = start_recorder()
      targets = [Expansion.target("a", recorder), Expansion.target("b", recorder)]

      assert {:ok, stats} = Expansion.run(model, targets, max_runs: 4, max_commands: 5)

      first = Expansion.sequences(recorder, ["a", "b"])

      for name <- ["a", "b"] do
        refute Enum.any?(first[name], &match?(%Blocked{}, &1))

        counts = stats |> Expansion.expansion_counts(name) |> Map.fetch!(Pay)
        refute Map.has_key?(counts, "Pay[0]")
        assert Map.get(counts, :forced, 0) == 0
        roots = Enum.count(first[name], &(match?(%Pay{}, &1) or match?(%Arm{}, &1)))
        assert Map.get(counts, "Pay[1]", 0) + Map.get(counts, "Pay[2]", 0) == roots
      end

      # The leaf-position precondition let Fire run after Arm.
      assert Enum.any?(first["a"] ++ first["b"], &match?(%Fire{}, &1))

      assert sequences(model, [{"a", nil}, {"b", nil}], max_runs: 4, max_commands: 5) == first
    end
  end

  describe "identity, forced" do
    test "a function returning [] and an entry list that is all withdrawn run the root as itself" do
      model =
        model!(Forced,
          commands: [Skip, Stuck, {Blocked, when: fn _state -> false end}],
          expansions: [
            {Skip, fn _skip, _state -> [] end},
            {Stuck, fn %Stuck{amount: a}, _state -> [[{Blocked, overrides: %{amount: a}}]] end}
          ]
        )

      recorder = start_recorder()
      targets = [Expansion.target("a", recorder), Expansion.target("b", recorder)]
      assert {:ok, stats} = Expansion.run(model, targets, max_runs: 3, max_commands: 4)

      entries = recorded(recorder)

      for name <- ["a", "b"] do
        executed = Expansion.executed(entries, name)
        refute Enum.any?(executed, &match?(%Blocked{}, &1))

        skips = Enum.count(executed, &match?(%Skip{}, &1))
        stucks = Enum.count(executed, &match?(%Stuck{}, &1))
        assert skips > 0
        assert stucks > 0

        counts = Expansion.expansion_counts(stats, name)
        assert Map.fetch!(counts, Skip) == %{forced: skips}
        assert Map.fetch!(counts, Stuck) == %{forced: stucks}
      end
    end
  end

  describe "an overrides: function that raises" do
    test "is a generation error naming the root, the entry and the leaf, not a re-draw" do
      model =
        model!(RaisingOverrides,
          expansions: [
            {Pay,
             fn _pay, _state ->
               [
                 [
                   {Credit, overrides: %{amount: 0}},
                   {Authorize, overrides: fn _state -> raise "no amount today" end}
                 ]
               ]
             end}
          ]
        )

      recorder = start_recorder()

      message =
        Expansion.error_message(fn -> Expansion.run(model, [Expansion.target("a", recorder)]) end)

      assert message =~ "Pay[0]"
      assert message =~ "Authorize"
      assert Expansion.setups(recorder) == 0
    end
  end

  describe "the roots alone" do
    test "max_commands counts roots and terminate_early?/3 sees only roots" do
      test_pid = self()

      model =
        model!(RootsOnly,
          expansions: [
            {Pay,
             fn %Pay{amount: a}, _state ->
               half = div(a, 2)
               [[{Credit, overrides: %{amount: half}}, {Credit, overrides: %{amount: a - half}}]]
             end}
          ],
          terminate: fn _state, command, _events ->
            send(test_pid, {:terminate_early, command})
            false
          end
        )

      recorder = start_recorder()
      targets = [Expansion.target("a", recorder), Expansion.target("b", recorder)]
      assert {:ok, stats} = Expansion.run(model, targets, max_runs: 1, max_commands: 5)

      assert stats.total_commands == 5

      for name <- ["a", "b"] do
        executed = Expansion.executed(recorded(recorder), name)
        assert length(executed) == 10
        assert Enum.all?(executed, &match?(%Credit{}, &1))
      end

      seen = for {:terminate_early, command} <- take_messages(:terminate_early), do: command
      assert length(seen) >= 5
      assert Enum.all?(seen, &match?(%Pay{}, &1))
    end
  end
end
