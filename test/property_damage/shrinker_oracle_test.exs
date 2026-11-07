defmodule PropertyDamage.ShrinkerOracleTest do
  # The shrinker does not run candidates. It hands each one to an oracle,
  # `(plan, mint_epoch) -> outcome`, and adopts a candidate when the oracle says
  # it failed with the original signature at the same or an earlier root. These
  # tests drive `Shrinker.shrink/2` with an in-memory oracle: a predicate over the
  # candidate's roots, with no scheduler, adapter or model process.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Placeholder, PlaceholderRegistry, Sequence, Shrinker}
  alias PropertyDamage.Sequence.{Position, Validator}
  alias PropertyDamage.Shrinker.Config
  alias PropertyDamage.Test.Commands.Link
  alias PropertyDamage.Test.Events.LinkAdded
  alias PropertyDamage.Test.FakeOracle
  alias PropertyDamage.Test.LinkModel
  alias PropertyDamage.Test.ShrinkOracle, as: O

  @plan_keys [:commands, :placeholder_registry, :setup_commands, :teardown_commands, :variants]

  # ----------------------------------------------------------------------------
  # Fixtures
  # ----------------------------------------------------------------------------

  defp deposit(account, amount), do: %O.Deposit{account: account, amount: amount}
  defp withdraw(account, amount), do: %O.Withdraw{account: account, amount: amount}
  defp audit(account), do: %O.Audit{account: account}

  # A rule that fails at the root `predicate` names, and passes otherwise.
  defp failing_at(predicate) do
    fn plan, _epoch ->
      case predicate.(plan.commands) do
        nil -> :passed
        root -> {:failed, root}
      end
    end
  end

  # Shrinks `commands` against the oracle `rule` and returns the result with
  # the oracle's calls. The original failure is at root `failed_at`, in target 0.
  defp shrink(commands, rule, failed_at, opts \\ []) do
    {model, opts} = Keyword.pop(opts, :model, O.Model)
    {setup, opts} = Keyword.pop(opts, :setup, [%O.Open{account: :alice}])
    {config, opts} = Keyword.pop(opts, :config, Config.new(shrink_arguments: false))
    {oracle, log} = FakeOracle.start(rule, O.signature())

    result =
      Shrinker.shrink(
        O.sequence(commands, setup),
        [
          failed_at_index: failed_at,
          failure_reason: O.failure(),
          variant_index: 0,
          model: model,
          targets: O.targets(),
          oracle: oracle,
          config: config
        ] ++ opts
      )

    calls = FakeOracle.calls(log)
    FakeOracle.stop(log)
    {result, calls}
  end

  defp roots(result), do: Sequence.to_list(result.sequence)

  defp failed_calls(calls),
    do:
      Enum.filter(calls, &(match?({:failed, _}, &1.answer) or match?({:failed, _, _}, &1.answer)))

  defp seen(calls), do: Enum.map(calls, & &1.plan.commands)

  # The commands of the original run for the linear cases: seven roots, the
  # first withdrawal that follows a deposit to the same account is at root 4.
  defp original do
    [
      deposit(:bob, 3),
      audit(:alice),
      deposit(:alice, 10),
      audit(:bob),
      withdraw(:alice, 5),
      deposit(:bob, 1),
      withdraw(:bob, 2)
    ]
  end

  defp minimal, do: [deposit(:alice, 10), withdraw(:alice, 5)]

  # ----------------------------------------------------------------------------
  # Controls: the predicates and the model can tell a failing candidate from a
  # passing one, so the tagged tests below can fail.
  # ----------------------------------------------------------------------------

  describe "controls" do
    test "withdraw-after-deposit is true on the original and the minimal repro, false on either command alone" do
      assert O.withdraw_after_deposit(original()) == 4
      assert O.withdraw_after_deposit(minimal()) == 1
      assert O.withdraw_after_deposit([withdraw(:alice, 5)]) == nil
      assert O.withdraw_after_deposit([deposit(:alice, 10)]) == nil
    end

    test "withdraw-after-deposit needs the same account" do
      assert O.withdraw_after_deposit([deposit(:bob, 10), withdraw(:alice, 5)]) == nil
    end

    test "the amount threshold separates a failing withdrawal from a smaller one" do
      assert O.withdraw_after_deposit([deposit(:alice, 0), withdraw(:alice, 5)], 5) == 1
      assert O.withdraw_after_deposit([deposit(:alice, 0), withdraw(:alice, 4)], 5) == nil
    end

    test "the overdraft predicate fails on one withdrawal and on two, and passes when covered" do
      assert O.overdraft([withdraw(:alice, 3)]) == 0
      assert O.overdraft([withdraw(:alice, 3), withdraw(:alice, 3)]) == 0
      assert O.overdraft([deposit(:alice, 5), withdraw(:alice, 3), withdraw(:alice, 3)]) == 2
      assert O.overdraft([deposit(:alice, 5), withdraw(:alice, 3)]) == nil
    end

    test "the two-withdrawal predicate fails later with a deposit and earlier without one" do
      a = withdraw(:alice, 3)
      b = withdraw(:alice, 4)
      c = withdraw(:alice, 5)

      assert two_withdrawals([deposit(:alice, 5), a, b, c]) == 3
      assert two_withdrawals([a, b, c]) == 0
      assert two_withdrawals([b, c]) == 0
      assert two_withdrawals([a]) == nil
    end

    test "the gated model rejects a withdrawal without an audit and accepts it after one" do
      valid? = fn commands ->
        commands |> O.sequence() |> Validator.valid_sequence?(O.GatedModel)
      end

      refute valid?.([deposit(:alice, 10), withdraw(:alice, 5)])
      assert valid?.([deposit(:alice, 10), audit(:alice), withdraw(:alice, 5)])
      assert valid?.([audit(:alice), withdraw(:alice, 5)])
    end

    test "the ungated model accepts the same candidate the gated model rejects" do
      assert O.sequence([deposit(:alice, 10), withdraw(:alice, 5)])
             |> Validator.valid_sequence?(O.Model)
    end
  end

  # ----------------------------------------------------------------------------
  # The shrinker against an oracle
  # ----------------------------------------------------------------------------

  describe "removal" do
    # unbuilt until the shrinker takes an oracle
    test "linear removal reaches the two-command repro" do
      {result, calls} = shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4)

      assert roots(result) == minimal()
      assert result.stop == :done
      # Truncation after the failing root, then three removals, each adopted;
      # a second pass and a second cycle find nothing more to drop.
      assert result.iterations == 11
      assert result.cycles == 2
      assert length(calls) == 11
      assert length(failed_calls(calls)) == 4

      # The last candidate the oracle failed is the one the shrinker kept.
      assert List.last(failed_calls(calls)).plan.commands == roots(result)
    end

    # unbuilt until the shrinker takes an oracle
    test "hierarchical removal drops a dependency chain, root by level" do
      # Eight zero-weight links, each consuming the previous link's external id,
      # then one heavy link: nine roots, above the granularity threshold. The
      # heavy link alone fails.
      sequence = link_chain(8)
      failing = &link_overweight/1
      total = length(Sequence.to_list(sequence))
      assert total > Config.new().granularity_threshold

      {oracle, log} = FakeOracle.start(failing_at(failing), O.signature())

      result =
        Shrinker.shrink(sequence,
          failed_at_index: total - 1,
          failure_reason: O.failure(),
          variant_index: 0,
          model: LinkModel,
          targets: O.targets(),
          oracle: oracle,
          config: Config.new(shrink_arguments: false)
        )

      calls = FakeOracle.calls(log)
      FakeOracle.stop(log)

      assert [%Link{weight: 101, parent: nil}] = Sequence.to_list(result.sequence)
      assert result.stop == :done
      assert result.iterations == 12
      assert length(calls) == 12

      # The deepest level of the dependency graph comes out first, one level
      # per candidate, then the whole of level 0 (which passes), then linear
      # removal drops the last chain link.
      assert calls |> Enum.map(&length(&1.plan.commands)) |> Enum.take(9) ==
               [8, 7, 6, 5, 4, 3, 2, 0, 1]

      assert Enum.at(calls, 7).answer == :passed
    end
  end

  describe "argument simplification" do
    # unbuilt until the shrinker takes an oracle
    test "an integer argument shrinks to the smallest value that still fails" do
      # The withdrawal fails from 5 up. Halving walks 40, 20, 10, 5, then 2,
      # which passes, so 5 is the least reachable value. The deposit's amount
      # does not matter and halves to 0.
      rule = failing_at(&O.withdraw_after_deposit(&1, 5))

      {result, calls} =
        shrink([deposit(:alice, 40), withdraw(:alice, 40)], rule, 1, config: Config.new())

      assert roots(result) == [deposit(:alice, 0), withdraw(:alice, 5)]
      assert result.stop == :done
      assert result.iterations == 15
      assert length(failed_calls(calls)) == 9

      # The candidate that halved the withdrawal below the threshold passed.
      assert Enum.any?(calls, fn call ->
               call.answer == :passed and
                 match?([_, %O.Withdraw{amount: 2}], call.plan.commands)
             end)
    end
  end

  describe "candidates the shrinker does not adopt" do
    # unbuilt until the shrinker takes an oracle
    test "a candidate whose setup failed is never adopted" do
      commands = [deposit(:alice, 10), audit(:alice), withdraw(:alice, 5)]

      rule = fn plan, _epoch ->
        if Enum.any?(plan.commands, &match?(%O.Audit{}, &1)),
          do: failing_at(&O.withdraw_after_deposit/1).(plan, 0),
          else: :setup_failed
      end

      {result, calls} = shrink(commands, rule, 2)

      assert Enum.any?(calls, &(&1.answer == :setup_failed)), "control: the branch fired"
      assert roots(result) == commands
      assert result.stop == :done
    end

    # unbuilt until the shrinker takes an oracle
    test "a candidate the model rejects never reaches the oracle" do
      # A withdrawal is valid only after an audit. Dropping the audit leaves a
      # deposit and a withdrawal that the predicate would call failing, so an
      # oracle that saw it would let the shrinker adopt a sequence the model
      # cannot produce.
      commands = [deposit(:bob, 3), deposit(:alice, 10), audit(:alice), withdraw(:alice, 5)]

      {result, calls} =
        shrink(commands, failing_at(&O.withdraw_after_deposit/1), 3, model: O.GatedModel)

      refute [deposit(:bob, 3), deposit(:alice, 10), withdraw(:alice, 5)] in seen(calls)
      refute [deposit(:alice, 10), withdraw(:alice, 5)] in seen(calls)
      assert roots(result) == [deposit(:alice, 10), audit(:alice), withdraw(:alice, 5)]
      assert result.stop == :done
      assert result.iterations == 10

      # The rejected candidate still costs an iteration, in each of three
      # passes, so the oracle saw three candidates fewer.
      assert length(calls) == 7
    end

    # unbuilt until the shrinker takes an oracle
    test "a failure with another signature is not adopted" do
      commands = [deposit(:alice, 10), audit(:alice), withdraw(:alice, 5)]
      other = Failure.signature(Failure.check_failed(:other_check, "other"), 0)

      rule = fn plan, _epoch ->
        if Enum.any?(plan.commands, &match?(%O.Audit{}, &1)),
          do: failing_at(&O.withdraw_after_deposit/1).(plan, 0),
          else: {:failed, O.withdraw_after_deposit(plan.commands) || 0, other}
      end

      {result, calls} = shrink(commands, rule, 2)

      assert Enum.any?(calls, &match?({:failed, _, ^other}, &1.answer)),
             "control: the branch fired"

      assert roots(result) == commands
    end

    # unbuilt until the shrinker takes an oracle
    test "a failure at a later root is not adopted" do
      # Two withdrawals fail. With a deposit first the failure is at the last
      # withdrawal (root 3 here); without one, at the first. Dropping the
      # deposit moves the failure to the first withdrawal, an earlier root,
      # which is adopted. The candidate that then drops that first withdrawal
      # still fails, but at the second withdrawal, a later root than the one on
      # record, so the shrinker keeps the first withdrawal.
      a = withdraw(:alice, 3)
      b = withdraw(:alice, 4)
      c = withdraw(:alice, 5)
      commands = [deposit(:alice, 5), a, b, c]

      {result, calls} = shrink(commands, failing_at(&two_withdrawals/1), 3)

      assert Enum.any?(calls, &(&1.plan.commands == [b, c] and &1.answer == {:failed, 0})),
             "control: the oracle failed the later candidate"

      assert roots(result) == [a, c]
    end
  end

  describe "stopping" do
    # unbuilt until the shrinker takes an oracle
    test "stops :max_iterations when the iteration cap is spent" do
      config = Config.new(max_iterations: 2, shrink_arguments: false)

      {result, calls} =
        shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4, config: config)

      assert result.stop == :max_iterations
      assert result.iterations == 2
      assert length(calls) == 2
      assert length(roots(result)) > length(minimal())
    end

    # unbuilt until the shrinker takes an oracle
    test "stops :max_time when the time budget is zero" do
      config = Config.new(max_time_ms: 0, shrink_arguments: false)

      {result, calls} =
        shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4, config: config)

      assert result.stop == :max_time
      assert result.iterations == 0
      assert calls == []
      assert roots(result) == original()
    end

    # unbuilt until the shrinker takes an oracle
    test "stops :done when it finishes inside its budget" do
      {result, _calls} = shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4)

      assert roots(result) == minimal()
      assert result.stop == :done
      assert result.iterations < Config.new().max_iterations
    end
  end

  describe "what the oracle is given" do
    # unbuilt until the shrinker takes an oracle
    test "each candidate gets a distinct, increasing, positive mint epoch" do
      {_result, calls} = shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4)
      epochs = Enum.map(calls, & &1.epoch)

      assert length(epochs) > 2
      assert Enum.all?(epochs, &(is_integer(&1) and &1 > 0))
      assert epochs == Enum.sort(Enum.uniq(epochs))
      assert epochs == Enum.to_list(1..length(epochs))
    end

    # unbuilt until the shrinker takes an oracle
    test "epochs continue from a counter the caller passes" do
      counter = :atomics.new(1, signed: false)
      :atomics.put(counter, 1, 41)

      {_result, calls} =
        shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4,
          mint_epoch_counter: counter
        )

      epochs = Enum.map(calls, & &1.epoch)
      assert hd(epochs) == 42
      assert epochs == Enum.to_list(42..(41 + length(epochs)))
    end

    # unbuilt until the shrinker takes an oracle
    test "every plan carries the five runner keys and the setup commands unchanged" do
      setup = [%O.Open{account: :alice}, %O.Open{account: :bob}]

      {_result, calls} =
        shrink(original(), failing_at(&O.withdraw_after_deposit/1), 4, setup: setup)

      assert calls != []

      for %{plan: plan} <- calls do
        assert plan |> Map.keys() |> Enum.sort() == @plan_keys
        assert plan.setup_commands == setup
        assert plan.variants == nil
        assert plan.teardown_commands == [%O.Close{}]
        assert plan.placeholder_registry != nil
      end
    end
  end

  # ----------------------------------------------------------------------------
  # A dependency chain of links, for the hierarchical case
  # ----------------------------------------------------------------------------

  # Each link after the first consumes the previous link's external id.
  defp link_chain(length) do
    parents =
      for i <- 0..(length - 1) do
        if i == 0,
          do: nil,
          else:
            Placeholder.new_at(
              LinkAdded,
              [:ref],
              Position.prefix(i - 1),
              0
            )
      end

    registry =
      parents
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(PlaceholderRegistry.new(), &PlaceholderRegistry.register(&2, &1))

    chain = Enum.map(parents, &%Link{parent: &1, weight: 0})

    (chain ++ [%Link{parent: nil, weight: 101}])
    |> Sequence.linear()
    |> Sequence.with_registry(registry)
  end

  # Two withdrawals fail: at the last one when a deposit is present, else at the
  # first.
  defp two_withdrawals(commands) do
    withdrawals =
      for {%O.Withdraw{}, index} <- Enum.with_index(commands), do: index

    cond do
      length(withdrawals) < 2 -> nil
      Enum.any?(commands, &match?(%O.Deposit{}, &1)) -> List.last(withdrawals)
      true -> hd(withdrawals)
    end
  end

  # The root at which the links' cumulative weight passes 100.
  defp link_overweight(commands) do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {%Link{weight: weight}, index}, total ->
      if total + weight > 100, do: {:halt, {:at, index}}, else: {:cont, total + weight}
    end)
    |> case do
      {:at, index} -> index
      _total -> nil
    end
  end
end
