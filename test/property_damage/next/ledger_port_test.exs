# The command structs are matched below, so the model compiles before the test.
Code.require_file("../../../corpus/next/support/ledger_model.exs", __DIR__)

defmodule PropertyDamage.Next.LedgerPortTest do
  # The ledger model of `corpus/next`, a port of the default corpus
  # directory's ledger model to the new engine.
  #
  # async: false because the corpus support files load once for the whole VM.
  use ExUnit.Case, async: false

  alias Corpus.Next.Ledger.{Deposit, Open, Withdraw}
  alias PropertyDamage.Corpus.{Engine, Entry, FireLog, Loader}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Step}

  @corpus "corpus/next"
  @max_steps 10

  setup_all do
    {:ok, [%Entry{name: "ledger"} = entry]} = Loader.load(@corpus, ["ledger"])
    {:ok, entry: entry}
  end

  # Runs the model against the ledger with `bug` and returns the run's
  # result with the number of times the bug fired.
  defp run(entry, bug, seed, max_plans) do
    {:ok, log} = FireLog.start_link()

    try do
      result =
        Next.run(
          model: entry.model,
          adapter: entry.adapter,
          config: %{bug: bug, fire_log: log},
          seed: seed,
          max_steps: @max_steps,
          max_plans: max_plans
        )

      {result, FireLog.total(log)}
    after
      FireLog.stop(log)
    end
  end

  test "the entry runs on the new engine as a regression entry", %{entry: entry} do
    assert entry.engine == Engine.Next
    assert entry.minimum == nil
    assert entry.plan_cap == 2
    assert entry.max_commands == @max_steps
    assert length(entry.seeds) == 24
  end

  test "a plan opens one account first, then deposits and withdraws within the balance",
       %{entry: entry} do
    for seed <- 1..20 do
      steps = Next.plan(entry.model, seed, max_steps: @max_steps).steps

      assert [%Step{command: %Open{}} | rest] = steps
      refute Enum.any?(rest, &match?(%Step{command: %Open{}}, &1))

      Enum.reduce(rest, 0, fn
        %Step{command: %Deposit{amount: amount}}, balance ->
          assert amount in 1..20
          balance + amount

        %Step{command: %Withdraw{amount: amount}}, balance ->
          assert balance > 0, "seed #{seed}: withdrew from an empty account"
          assert amount in 1..balance
          balance - amount
      end)
    end
  end

  test "some withdrawal in the sample exceeds a deposit's 20", %{entry: entry} do
    amounts =
      for seed <- 1..20,
          %Step{command: %Withdraw{amount: amount}} <-
            Next.plan(entry.model, seed, max_steps: @max_steps).steps,
          do: amount

    assert Enum.any?(amounts, &(&1 > 20))
  end

  test "with the bug off, plans run clean and nothing fires", %{entry: entry} do
    for seed <- 1..5 do
      assert {{:ok, _}, 0} = run(entry, nil, seed, 20)
    end
  end

  test "with the bug on, a failing seed reports the drift, with the bug fired", %{entry: entry} do
    assert {{:error, %Failure{reason: {:check, _name, message}} = failure}, fires} =
             run(entry, :double_debit_from_12, 1, 2)

    assert fires > 0
    assert message =~ "Reported balance differs from the ledger"
    assert failure.plan_number in 1..2

    assert Enum.any?(
             failure.plan.steps,
             &match?(%Step{command: %Withdraw{amount: a}} when a >= 12, &1)
           )
  end

  test "the harness finds the bug with it firing on the seeds that draw a large withdrawal",
       %{entry: entry} do
    for seed <- [1, 2, 3, 24, 39, 40] do
      result = Engine.Next.run(entry, seed, entry.plan_cap)

      assert result.found?, "seed #{seed}: bug not found"
      assert result.bug_fired?, "seed #{seed}: failed without the seeded bug firing"
      assert Enum.any?(result.shrunk, &(&1.command == :withdraw and &1.amount >= 12))
    end
  end

  test "a seed whose two plans draw no withdrawal of 12 or more passes with the bug on",
       %{entry: entry} do
    for seed <- [14, 15, 33] do
      result = Engine.Next.run(entry, seed, entry.plan_cap)

      refute result.found?, "seed #{seed}: found a failure"
      assert result.fires == 0
    end
  end
end
