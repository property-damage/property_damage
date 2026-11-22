defmodule PropertyDamage.Next.CorpusEngineTest do
  # async: false because the corpus support files load once for the whole VM.
  use ExUnit.Case, async: false

  alias PropertyDamage.Corpus.{Engine, Entry, FireLog, Loader}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.Test.{Leak, Terms}

  @corpus "corpus/next"
  @plan_cap 200
  @seeds [1, 2]

  setup_all do
    {:ok, [%Entry{name: "lost_full_refund"} = entry]} = Loader.load(@corpus, ["lost_full_refund"])
    {:ok, entry: entry}
  end

  # A step as the harness writes a plan: the command's fields plus its name,
  # with a field the system minted written as `:id`.
  defp plain(plan) do
    for %Next.Step{command: %module{} = command} <- Terms.steps_of(plan) do
      command
      |> Map.from_struct()
      |> Map.new(fn
        {field, %Next.Placeholder{}} -> {field, :id}
        pair -> pair
      end)
      |> Map.put(
        :command,
        module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
      )
    end
  end

  test "the engine has its own name and the entry runs on it", %{entry: entry} do
    assert Engine.Next.name() == "property_damage_next"
    assert entry.engine == Engine.Next
  end

  test "finds the bug with the bug firing, and shrinks it", %{entry: entry} do
    for seed <- @seeds do
      result = Engine.Next.run(entry, seed, @plan_cap)

      assert result.found?, "seed #{seed}: bug not found within #{@plan_cap} plans"
      assert result.bug_fired?, "seed #{seed}: failed without the seeded bug firing"
      assert result.fires > 0
      assert result.plans_until_found in 1..@plan_cap
      assert result.shrink_runs > 0

      assert [_ | _] = result.shrunk
      assert length(result.shrunk) <= entry.max_commands
      assert Leak.find(result.shrunk) == []

      for step <- result.shrunk do
        refute is_struct(step)
        assert step.command in [:pay, :refund]
      end

      assert Enum.any?(result.shrunk, &match?(%{command: :refund, payment_id: :id}, &1))
    end
  end

  test "reports the shrunk failing plan, its shrink runs and the plan it failed on",
       %{entry: entry} do
    for seed <- @seeds do
      result = Engine.Next.run(entry, seed, @plan_cap)

      {:ok, log} = FireLog.start_link()

      direct =
        try do
          Next.run(
            model: entry.model,
            adapter: entry.adapter,
            config: %{bug: entry.bug, fire_log: log},
            seed: seed,
            max_steps: entry.max_commands,
            max_plans: @plan_cap
          )
        after
          FireLog.stop(log)
        end

      assert {:error, %Next.Failure{} = failure} = direct
      assert result.plans_until_found == failure.plan_number
      assert result.shrink_runs == Map.fetch!(failure, :shrink_runs)
      assert result.shrunk == plain(failure.plan)
    end
  end

  test "with the bug off, finds nothing and the bug never fires", %{entry: entry} do
    for seed <- @seeds do
      result = Engine.Next.run(%{entry | bug: nil}, seed, @plan_cap)

      refute result.found?, "seed #{seed}: failed with the bug off"
      assert result.fires == 0
      refute result.bug_fired?
      assert result.plans_until_found == nil
      assert result.shrunk == nil
    end
  end
end
