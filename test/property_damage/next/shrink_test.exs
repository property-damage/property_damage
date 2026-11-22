defmodule PropertyDamage.Next.ShrinkTest do
  # run/1 shrinks the first failing plan by editing its journal and
  # rebuilding each candidate plan from the edited journal. These tests read
  # the final plan, its journal and the candidates the system saw; they
  # never name the shrinker's own modules.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal, Step}
  alias PropertyDamage.Next.Test.Scheme
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Shrink.{Amount, Note, Split, Stock, Till}
  alias PropertyDamage.Next.Test.{Surface, Terms}

  # --- Helpers

  defp run(opts), do: Next.run(Keyword.merge([max_plans: 200], opts))

  defp scheme_run(seed, opts \\ []) do
    [
      model: Scheme.Model,
      adapter: Scheme.Adapter,
      seed: seed,
      max_steps: 20,
      max_plans: 10,
      config: %{fault: :skip_credit}
    ]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  # Every execution the generic adapter reported, in order, as a list of
  # {instance, [command]} pairs.
  defp executions do
    collect([])
    |> Enum.reverse()
    |> Enum.reduce([], fn
      {:shrink_setup, instance}, acc ->
        [{instance, []} | acc]

      {:shrink_executed, instance, command}, [{instance, commands} | acc] ->
        [{instance, commands ++ [command]} | acc]
    end)
    |> Enum.reverse()
  end

  defp collect(acc) do
    receive do
      {:shrink_setup, _} = message -> collect([message | acc])
      {:shrink_executed, _, _} = message -> collect([message | acc])
    after
      0 -> acc
    end
  end

  # The executions after the plan that first failed: the shrink's candidates.
  defp candidates(%Failure{plan_number: number}, executions), do: Enum.drop(executions, number)

  defp commands(%Failure{plan: plan}), do: Enum.map(plan.steps, & &1.command)

  defp original(failure), do: Surface.field(failure, :original)
  defp shrink_runs(failure), do: Surface.field(failure, :shrink_runs)

  # The keys of a slot's entries in a journal.
  defp slot_keys(%Journal{entries: entries}, step) do
    entries |> Map.keys() |> Enum.filter(&(elem(&1, 0) == step))
  end

  # A final journal holds exactly the draws of its plan: rebuilding the plan
  # from it writes back the same entries, and a slot with no step holds at
  # most an empty pick.
  defp assert_exact_journal(model, %Failure{journal: journal, plan: plan}) do
    rebuilt = Next.plan(model, journal)
    assert rebuilt.journal.entries == journal.entries
    assert rebuilt.steps == plan.steps
    assert rebuilt.withdrawn == plan.withdrawn

    stepped = MapSet.new(plan.steps, & &1.key)

    for {key, entry} <- journal.entries, not MapSet.member?(stepped, elem(key, 0)) do
      assert {_step, :pick} = key, "a slot with no step holds #{inspect(key)}"
      assert entry == {:empty}
    end
  end

  # Saves, loads and replays a final journal: the plan and the failure must
  # come back unchanged.
  defp assert_replays(failure, opts) do
    loaded = failure.journal |> Journal.to_binary() |> Journal.from_binary()
    assert {:error, %Failure{} = again} = Next.replay(loaded, opts)

    assert again.plan.steps == failure.plan.steps
    assert again.withdrawn == failure.withdrawn
    assert again.step == failure.step
    assert again.reason == failure.reason
  end

  # --- Integer order

  describe "an integer shrinks to its lower bound first, then bisects" do
    test "a failure that needs an amount of at least 37 shrinks to exactly 37" do
      fails? = fn %Amount{amount: amount}, _earlier -> amount >= 37 end

      checked =
        for seed <- 1..6 do
          opts = [
            model: Shrink.AmountModel,
            adapter: Shrink.Adapter,
            seed: seed,
            max_steps: 1,
            config: %{fails?: fails?, recorder: self()}
          ]

          assert {:error, %Failure{} = failure} = run(opts)
          runs = executions()
          [%Amount{amount: first}] = commands(%{failure | plan: original(failure).plan})

          assert [%Amount{amount: 37}] = commands(failure)

          tried =
            for {_instance, [%Amount{amount: amount}]} <- candidates(failure, runs), do: amount

          if first > 37, do: assert(hd(tried) == 1, "the first value tried was #{hd(tried)}")
          first
        end

      assert Enum.any?(checked, &(&1 > 37))
    end
  end

  # --- Block removal

  describe "steps are removed from the journal" do
    test "a failure on the fifth refund of one payment shrinks by removing steps, failing the same way" do
      # One payment and five refunds is the smallest plan; reaching it is a
      # corpus measurement, not something this test forces.
      failures =
        for seed <- 1..15,
            {:error, %Failure{} = failure} <-
              [
                run(
                  model: Till.Model,
                  adapter: Till.Adapter,
                  seed: seed,
                  max_steps: 14,
                  config: %{bug: true}
                )
              ],
            do: failure

      assert length(failures) >= 3

      for failure <- failures do
        found = original(failure).plan.steps
        refunds = for %Till.Refund{} = refund <- commands(failure), do: refund

        assert failure.reason == {:adapter_error, :fifth_refund}

        assert %Step{command: %Till.Refund{}} =
                 Enum.find(failure.plan.steps, &(&1.key == failure.step))

        assert length(refunds) >= 5
        assert length(failure.plan.steps) <= length(found)

        if length(failure.plan.steps) < length(found),
          do: assert(Enum.any?(Map.values(failure.journal.entries), &(&1 == {:empty})))

        assert_exact_journal(Till.Model, failure)
        assert_replays(failure, model: Till.Model, adapter: Till.Adapter, config: %{bug: true})
      end

      assert Enum.any?(failures, &(length(&1.plan.steps) < length(original(&1).plan.steps)))
    end
  end

  # --- The result of a shrink

  describe "the failure after a shrink" do
    test "two shrinks of the same run give the same final plan and the same number of runs" do
      for seed <- [1, 2, 3, 5] do
        assert {:error, %Failure{} = first} = scheme_run(seed)
        assert {:error, %Failure{} = second} = scheme_run(seed)

        assert first.plan == second.plan
        assert first.journal == second.journal
        assert first.step == second.step
        assert first.reason == second.reason
        assert shrink_runs(first) == shrink_runs(second)
      end
    end

    test "shrink: false returns the first failing plan with no shrink runs" do
      for seed <- [1, 2, 3] do
        plan = Next.plan(Scheme.Model, seed, max_steps: 20)
        assert {:error, %Failure{} = failure} = scheme_run(seed, shrink: false)

        assert failure.plan_number == 1
        assert failure.plan.steps == plan.steps
        assert shrink_runs(failure) == 0
        assert original(failure).plan == failure.plan
        assert original(failure).journal == failure.journal
        assert original(failure).step == failure.step
        assert original(failure).reason == failure.reason
        assert original(failure).withdrawn == failure.withdrawn
      end
    end

    test "the original holds the first failing plan; the plan number and seed stay its own" do
      for seed <- [1, 2, 3] do
        assert {:error, %Failure{} = unshrunk} = scheme_run(seed, shrink: false)
        assert {:error, %Failure{} = shrunk} = scheme_run(seed)

        assert original(shrunk) == %{
                 plan: unshrunk.plan,
                 journal: unshrunk.journal,
                 step: unshrunk.step,
                 reason: unshrunk.reason,
                 withdrawn: unshrunk.withdrawn
               }

        assert shrunk.plan_number == unshrunk.plan_number
        assert shrunk.seed == unshrunk.seed
        assert length(shrunk.plan.steps) <= length(unshrunk.plan.steps)
        assert shrink_runs(shrunk) > 0
      end
    end

    test "the final plan is the plan its journal builds, and it still fails the same way" do
      for seed <- [1, 2, 3, 5, 8] do
        assert {:error, %Failure{} = failure} = scheme_run(seed)

        assert_exact_journal(Scheme.Model, failure)
        assert {:check, :balance_matches, _message} = failure.reason

        assert_replays(failure,
          model: Scheme.Model,
          adapter: Scheme.Adapter,
          config: %{fault: :skip_credit}
        )
      end
    end

    test "max_shrink_runs bounds the candidate plans executed while shrinking" do
      fails? = fn
        %Stock.Take{count: count}, _earlier -> count >= 3
        _command, _earlier -> false
      end

      for limit <- [1, 3], seed <- [1, 2, 3] do
        opts = [
          model: Stock.Model,
          adapter: Shrink.Adapter,
          seed: seed,
          max_steps: 10,
          max_shrink_runs: limit,
          config: %{fails?: fails?, recorder: self()}
        ]

        case run(opts) do
          {:error, %Failure{} = failure} ->
            runs = executions()
            assert shrink_runs(failure) <= limit
            assert length(candidates(failure, runs)) == shrink_runs(failure)

          {:ok, _} ->
            executions()
        end
      end
    end

    test "the shrink runs count every execution after the plan that first failed" do
      fails? = fn
        %Stock.Take{count: count}, _earlier -> count >= 3
        _command, _earlier -> false
      end

      counted =
        for seed <- 1..5,
            {:error, %Failure{} = failure} <- [
              run(
                model: Stock.Model,
                adapter: Shrink.Adapter,
                seed: seed,
                max_steps: 10,
                config: %{fails?: fails?, recorder: self()}
              )
            ] do
          assert length(candidates(failure, executions())) == shrink_runs(failure)
          seed
        end

      assert counted != []
    end
  end

  # --- Fitting during the search

  describe "a value that sat on a bound that moved" do
    test "moves to the new bound once, only after the candidate that kept it passed" do
      fails? = fn %Split{cut: cut, rest: rest}, _earlier -> rest == 101 - cut end

      checked =
        for seed <- 1..8,
            {:error, %Failure{} = failure} <- [
              run(
                model: Shrink.SplitModel,
                adapter: Shrink.Adapter,
                seed: seed,
                max_steps: 1,
                max_plans: 2_000,
                config: %{fails?: fails?, recorder: self()}
              )
            ],
            [%Split{cut: cut, rest: rest}] = commands(%{failure | plan: original(failure).plan}),
            cut > 1 do
          tried =
            for {_instance, [%Split{} = split]} <- candidates(failure, executions()),
                do: {split.cut, split.rest}

          kept = Enum.find_index(tried, &(&1 == {1, rest}))

          assert kept != nil, "no candidate kept #{rest} with the cut at 1"
          refute {1, 100} in Enum.take(tried, kept)

          # The new bound is tried once, later in the shrink. A last execution
          # of the final plan itself is not a try.
          retries = tried |> Enum.drop(kept + 1) |> Enum.count(&(&1 == {1, 100}))
          assert retries == 1 or (retries == 2 and List.last(tried) == {1, 100})
          assert [%Split{cut: 1, rest: 100}] = commands(failure)
          seed
        end

      assert checked != []
    end
  end

  # --- Empty slots

  describe "an empty pick" do
    test "yields no step, draws nothing, is written back and withdraws nothing" do
      seed =
        Enum.find(1..200, fn seed ->
          match?(
            [%Step{key: {0, 1}}, %Step{key: {0, 2}}, %Step{key: {0, 3}} | _],
            Next.plan(Scheme.Model, seed, max_steps: 10).steps
          )
        end)

      original = Next.plan(Scheme.Model, seed, max_steps: 10)
      entries = Map.put(original.journal.entries, {{0, 2}, :pick}, {:empty})
      rebuilt = Next.plan(Scheme.Model, %{original.journal | entries: entries})

      refute Enum.any?(rebuilt.steps, &(&1.key == {0, 2}))
      assert hd(rebuilt.steps) == hd(original.steps)
      assert Enum.any?(rebuilt.steps, &match?(%Step{key: {0, slot}} when slot > 2, &1))
      assert slot_keys(rebuilt.journal, {0, 2}) == [{{0, 2}, :pick}]
      assert rebuilt.journal.entries[{{0, 2}, :pick}] == {:empty}
      refute Enum.any?(rebuilt.withdrawn, &Terms.mentions?(&1, {0, 2}))
    end
  end

  # --- StreamData values

  describe "a StreamData value after a shrink" do
    test "records a path that walks to the stored value on the key's seed" do
      generator = StreamData.string(:alphanumeric, max_length: 12)
      fails? = fn %Note{text: text}, _earlier -> String.length(text) >= 2 end

      changed =
        for seed <- 1..10,
            {:error, %Failure{} = failure} <- [
              run(
                model: Shrink.NoteModel,
                adapter: Shrink.Adapter,
                seed: seed,
                max_steps: 1,
                config: %{fails?: fails?}
              )
            ] do
          [%Step{key: step, command: %Note{text: text}}] = failure.plan.steps
          key = {step, :command, :text}
          [%Note{text: first}] = commands(%{failure | plan: original(failure).plan})

          assert {:stream_data, ^text, path} = failure.journal.entries[key]

          assert Surface.walk(generator, Journal.key_seed(failure.journal.seed, key), path) ==
                   {text, path}

          assert original(failure).journal.entries[key] == {:stream_data, first, []}
          if text != first, do: assert(path != [])
          text != first
        end

      assert Enum.any?(changed)
    end
  end

  # --- Every value fits its current generator

  describe "a shrunk plan" do
    property "holds only values its current generators can draw" do
      tag = StreamData.string(:alphanumeric, max_length: 5)

      fails? = fn
        %Stock.Take{count: count}, earlier ->
          count >= 3 and
            Enum.any?(earlier, &match?(%Stock.Put{tag: t} when byte_size(t) >= 2, &1))

        _command, _earlier ->
          false
      end

      check all(seed <- StreamData.integer(1..1_000_000), max_runs: 25) do
        case run(
               model: Stock.Model,
               adapter: Shrink.Adapter,
               seed: seed,
               max_steps: 8,
               config: %{fails?: fails?}
             ) do
          {:error, %Failure{journal: journal, plan: plan}} ->
            Enum.reduce(plan.steps, %{}, fn %Step{key: key, command: command}, state ->
              entry = &Map.fetch!(journal.entries, {key, :command, &1})

              fits!(
                command,
                state,
                entry,
                Journal.key_seed(journal.seed, {key, :command, :tag}),
                tag
              )
            end)

          {:ok, _} ->
            :ok
        end
      end
    end
  end

  # Asserts each field of `command` lies in the domain its generator gives on
  # `state`, the predicted state before the step, and returns the state after.
  defp fits!(%Stock.Put{key: key, size: size, tag: text}, state, entry, tag_seed, tag) do
    keys = Stock.Put.keys()
    assert entry.(:key) == {:member, key, Enum.find_index(keys, &(&1 == key))}
    assert entry.(:size) == {:integer, size, 1..50}
    assert {:stream_data, ^text, path} = entry.(:tag)
    assert Surface.walk(tag, tag_seed, path) == {text, path}
    Map.put(state, key, size)
  end

  defp fits!(%Stock.Take{key: key, count: count}, state, entry, _tag_seed, _tag) do
    keys = Stock.Take.stocked(state)
    assert key in keys
    assert entry.(:key) == {:member, key, Enum.find_index(keys, &(&1 == key))}
    assert entry.(:count) == {:integer, count, 1..Map.fetch!(state, key)}
    assert count in 1..Map.fetch!(state, key)
    state
  end

  # --- Final journals of the fixtures

  describe "the final journal of each fixture's shrink" do
    test "saves, loads and replays to the identical plan and the same failure" do
      fixtures = [
        {Shrink.AmountModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> c.amount >= 37 end}},
        {Shrink.SplitModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> c.rest == 101 - c.cut end}},
        {Shrink.NoteModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> byte_size(c.text) >= 2 end}},
        {Till.Model, Till.Adapter, 14, %{bug: true}},
        {Stock.Model, Shrink.Adapter, 8,
         %{fails?: fn c, _ -> match?(%Stock.Take{count: n} when n >= 3, c) end}}
      ]

      checked =
        for {model, adapter, max_steps, config} <- fixtures,
            seed <- 1..4,
            {:error, %Failure{} = failure} <- [
              run(
                model: model,
                adapter: adapter,
                seed: seed,
                max_steps: max_steps,
                max_plans: 2_000,
                config: config
              )
            ] do
          assert_exact_journal(model, failure)
          assert_replays(failure, model: model, adapter: adapter, config: config)
          model
        end

      assert checked |> Enum.uniq() |> length() == 5
    end
  end
end
