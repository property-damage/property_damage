# The command structs are matched below, so the model compiles before the test.
Code.require_file("../../../corpus/next/support/ledger_model.exs", __DIR__)

defmodule PropertyDamage.Next.LedgerDomainsTest do
  # The final plans of the ledger model's saved seeds hold only values the
  # model's generators can draw, and their journals save, load and replay.
  #
  # The domain check walks a plan the way generation does: it keeps the
  # model's projection state, folds the simulator's events into it, and at
  # each step asks the spec whether the step was offered and the command's
  # generator which domain each field draws from.
  #
  # async: false because the corpus support files load once for the whole VM.
  use ExUnit.Case, async: false

  alias Corpus.Next.Ledger.{Deposit, Open, Withdraw}
  alias PropertyDamage.Corpus.{Entry, FireLog, Loader}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Gen, Journal, Model, Placeholder, Plan, Step}

  @corpus "corpus/next"

  setup_all do
    {:ok, [%Entry{name: "ledger"} = entry]} = Loader.load(@corpus, ["ledger"])

    failures =
      for seed <- entry.seeds, {:error, %Failure{} = failure} <- [run(entry, seed)], do: failure

    {:ok, entry: entry, failures: failures}
  end

  defp run(entry, seed) do
    {:ok, log} = FireLog.start_link()

    try do
      Next.run(
        model: entry.model,
        adapter: entry.adapter,
        config: %{bug: entry.bug, fire_log: log},
        seed: seed,
        max_steps: entry.max_commands,
        max_plans: entry.plan_cap
      )
    after
      FireLog.stop(log)
    end
  end

  # The steps of `plan` with the projection state each one was drawn in.
  defp states(model, %Plan{steps: steps}), do: states(model, steps)

  defp states(model, steps) do
    specs = Map.new(Model.specs!(model), &{&1.id, &1})
    projection = model.command_sequence_projection()
    simulator = model.simulator()

    {rows, _state} =
      Enum.map_reduce(steps, projection.init(), fn %Step{} = step, state ->
        events = step.command |> simulator.simulate(state) |> mark_externals(step.key)

        {{step, specs[step.spec_id], state},
         Enum.reduce(events, state, &projection.apply(&2, &1))}
      end)

    rows
  end

  # Puts a placeholder where a simulated event holds an external value, as
  # generation does, so a later command's pick of that value compares equal.
  defp mark_externals(events, key) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      event
      |> Map.from_struct()
      |> Enum.reduce(event, fn {field, value}, acc ->
        if PropertyDamage.External.external?(value),
          do: Map.put(acc, field, %Placeholder{step: key, event_index: index, path: [field]}),
          else: acc
      end)
    end)
  end

  # Every way a step of `steps` falls outside what the model offers: a step
  # its `when:` did not offer, or a field value outside the domain the
  # command's generator describes in that state.
  defp violations(model, steps) do
    for {step, spec, state} <- states(model, steps),
        violation <- offered(step, spec, state) ++ domains(step, spec, state),
        do: violation
  end

  defp offered(step, %{when: predicate}, state) do
    if is_nil(predicate) or predicate.(state) not in [false, nil],
      do: [],
      else: [{step.key, :when, state}]
  end

  defp domains(%Step{command: %module{} = command} = step, spec, state) do
    for {field, %Gen{kind: kind, domain: domain}} <-
          module.generator(state, spec.command_opts),
        value = Map.fetch!(command, field),
        not member?(kind, domain, value),
        do: {step.key, field, value}
  end

  defp member?(:integer, range, value), do: is_integer(value) and value in range
  defp member?(:member, list, value), do: value in list

  defp balance_before(model, steps, index) do
    {_step, _spec, state} = Enum.at(states(model, steps), index)
    state.balance
  end

  defp replace_amount(steps, index, amount) do
    List.update_at(steps, index, fn %Step{command: command} = step ->
      %{step | command: %{command | amount: amount}}
    end)
  end

  defp describe(%Plan{steps: steps}) do
    Enum.map_join(steps, ", ", fn
      %Step{command: %Open{}} -> "open"
      %Step{command: %Deposit{amount: amount}} -> "dep #{amount}"
      %Step{command: %Withdraw{amount: amount}} -> "wd #{amount}"
    end)
  end

  test "every value in each final plan is one the model's generators draw",
       %{entry: entry, failures: failures} do
    assert length(failures) == 21

    for %Failure{plan: plan, seed: seed} <- failures do
      assert violations(entry.model, plan.steps) == [],
             "seed #{seed}: final plan [#{describe(plan)}] holds a value outside the model's domains"
    end
  end

  test "the domain check reports a withdrawal above the balance and a deposit above 20",
       %{entry: entry, failures: failures} do
    %Failure{plan: plan} = hd(failures)
    steps = plan.steps
    assert violations(entry.model, steps) == []

    wd = Enum.find_index(steps, &match?(%Step{command: %Withdraw{}}, &1))
    dep = Enum.find_index(steps, &match?(%Step{command: %Deposit{}}, &1))
    assert wd && dep

    over_balance = replace_amount(steps, wd, balance_before(entry.model, steps, wd) + 1)
    wd_key = Enum.at(steps, wd).key

    assert {wd_key, :amount, balance_before(entry.model, steps, wd) + 1} in violations(
             entry.model,
             over_balance
           )

    over_twenty = replace_amount(steps, dep, 21)
    dep_key = Enum.at(steps, dep).key
    assert {dep_key, :amount, 21} in violations(entry.model, over_twenty)

    wrong_account =
      List.update_at(steps, dep, fn %Step{command: command} = step ->
        %{step | command: %{command | account_id: "acct-other"}}
      end)

    assert {dep_key, :account_id, "acct-other"} in violations(entry.model, wrong_account)
  end

  test "every final journal saves, loads and replays to the same plan and the same failure",
       %{entry: entry, failures: failures} do
    assert length(failures) == 21

    for %Failure{} = failure <- failures do
      {:ok, log} = FireLog.start_link()

      try do
        binary = Journal.to_binary(failure.journal)

        assert {:error, %Failure{} = replayed} =
                 Next.replay(binary,
                   model: entry.model,
                   adapter: entry.adapter,
                   config: %{bug: entry.bug, fire_log: log}
                 )

        assert replayed.reason == failure.reason, "seed #{failure.seed}: another failure"
        assert replayed.step == failure.step, "seed #{failure.seed}: another failing step"
        assert replayed.plan.steps == failure.plan.steps, "seed #{failure.seed}: another plan"
      after
        FireLog.stop(log)
      end
    end
  end
end
