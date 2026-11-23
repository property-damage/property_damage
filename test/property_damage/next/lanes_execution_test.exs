defmodule PropertyDamage.Next.LanesExecutionTest do
  # How a plan with two lanes is built and executed: each lane is generated
  # from the predicted state after the prefix, events fold and checks run in
  # the order steps complete, an adapter's bad answer fails the step, the
  # report counts lane steps like prefix steps, a lane slot whose pick is no
  # longer offered is withdrawn with its entries, and mint markers keep one
  # value per stamp across the lanes.
  use ExUnit.Case, async: true

  alias PropertyDamage.Mint
  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Placeholder, StepSpec}
  alias PropertyDamage.Next.Test.Lanes
  alias PropertyDamage.Next.Test.Lanes.{Deposit, OnceModel, Withdraw}
  alias PropertyDamage.Next.Test.Retry
  alias PropertyDamage.Next.Test.Shrink.Till

  @moduletag timeout: 120_000

  defmodule Job do
    @moduledoc false
    use PropertyDamage.Next.Command

    defstruct [:id]

    def generator(_state, _opts), do: %{id: integer(1..1_000_000_000)}
  end

  defmodule Rare do
    @moduledoc false
    use PropertyDamage.Next.Command

    defstruct [:n]

    def generator(_state, _opts), do: %{n: integer(1..3)}
  end

  defmodule Done do
    @moduledoc false
    defstruct [:id]
  end

  defmodule Order do
    @moduledoc false
    # Folds the ids of the completed jobs in order. Its check tells the
    # calling process the folded order each time a job completes.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{order: []}

    @impl true
    def apply(state, %Done{id: id}), do: %{state | order: state.order ++ [id]}
    def apply(state, _event), do: state

    @check every: PropertyDamage.Next.LanesExecutionTest.Job
    def report_order(state, _command) do
      send(self(), {:checked, state.order})
      true
    end
  end

  defmodule JobModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.LanesExecutionTest.{Job, Order, Rare}
    alias PropertyDamage.Next.Test.Fixtures.NullSimulator

    def steps, do: StepSpec.normalize([{Job, weight: 10_000}, {Rare, weight: 1}])
    def simulator, do: NullSimulator
    def command_sequence_projection, do: Order
    def check_projections, do: [Order]
  end

  defmodule JobAdapter do
    @moduledoc false
    # Each job yields once, then answers `Done`. Config key `:answer`: what
    # the job answers instead, `{:first, term}` from execute/3 or
    # `{:continuation, term}` from its continuation, or `:raise` to raise
    # in the continuation.
    @behaviour PropertyDamage.Next.Adapter

    alias PropertyDamage.Next.LanesExecutionTest.Done

    @impl true
    def setup(config, _runtime), do: {:ok, config}

    @impl true
    def execute(command, _assigns, %{answer: {:first, answer}}) when is_map(command),
      do: answer

    def execute(%{id: id}, _assigns, config) do
      {:yield,
       fn ->
         case Map.get(config, :answer) do
           {:continuation, answer} -> answer
           :raise -> raise "the continuation broke"
           _none -> {:ok, [%Done{id: id}]}
         end
       end}
    end

    def execute(_command, _assigns, _config), do: {:ok, []}
  end

  @once [max_steps: 1, lanes: 2, lane_steps: 1, yields: 1]

  defp in_lane(plan, lane), do: Enum.filter(plan.steps, &match?(%{key: {^lane, _slot}}, &1))

  defp checked(acc \\ []) do
    receive do
      {:checked, order} -> checked([order | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A seed whose plan, built with `opts`, satisfies `predicate`.
  defp seed_where(model, opts, predicate) do
    seed = Enum.find(1..2_000, &predicate.(Next.plan(model, &1, opts)))
    assert is_integer(seed), "no seed in 1..2000 builds the plan this test needs"
    seed
  end

  describe "an adapter's answer" do
    @job [model: JobModel, adapter: JobAdapter, seed: 1, max_steps: 1, shrink: false]

    test "that is neither {:ok, events}, {:yield, continuation} nor {:error, reason} fails the step" do
      for answer <- [{:yield, :not_a_function}, {:yield, fn _x -> :one_arity end}, :done] do
        assert {:error, failure} = Next.run(@job ++ [config: %{answer: {:first, answer}}])
        assert {:raise, %ArgumentError{message: message}} = failure.reason
        assert failure.step == {0, 1}

        assert message ==
                 "#{inspect(JobAdapter)}.execute/3 must return {:ok, events}, " <>
                   "{:yield, continuation} or {:error, reason}, got: #{inspect(answer)}"
      end
    end

    test "of a continuation that is not one of those fails the step and names the continuation" do
      for answer <- [:done, {:yield, :again}] do
        assert {:error, failure} = Next.run(@job ++ [config: %{answer: {:continuation, answer}}])
        assert {:raise, %ArgumentError{message: message}} = failure.reason

        assert message ==
                 "a continuation of #{inspect(JobAdapter)}.execute/3 must return " <>
                   "{:ok, events}, {:yield, continuation} or {:error, reason}, " <>
                   "got: #{inspect(answer)}"
      end
    end

    test "a raise in a continuation fails the step as a raise in execute/3 does" do
      assert {:error, failure} = Next.run(@job ++ [config: %{answer: :raise}])
      assert {:raise, %RuntimeError{message: "the continuation broke"}} = failure.reason
      assert failure.step == {0, 1}
    end
  end

  describe "completion order" do
    test "events fold and checks run in the order steps complete, across lanes" do
      opts = [max_steps: 0, lanes: 2, lane_steps: 1, yields: 1]

      seed =
        seed_where(JobModel, opts, fn plan ->
          match?([%{command: %Job{}}, %{command: %Job{}}], plan.steps)
        end)

      plan = Next.plan(JobModel, seed, opts)
      [%{key: {1, 1}, command: %Job{id: a}}, %{key: {2, 1}, command: %Job{id: b}}] = plan.steps

      # Lane 2 runs both its parts first, so its job completes first.
      journal = Lanes.with_schedule(plan.journal, %{{1, 1} => [2, 2]})
      checked()

      assert {:ok, _} = Next.replay(journal, model: JobModel, adapter: JobAdapter)
      assert checked() == [[b], [b, a]]
    end
  end

  describe "the report" do
    test "counts the assigns of lane steps and the specs offered or drawn only in a lane" do
      run = [
        model: Lanes.Ack.Model,
        adapter: Lanes.Ack.Adapter,
        seed: 1,
        max_steps: 0,
        lanes: 2,
        lane_steps: 2,
        yields: 1,
        max_plans: 5
      ]

      assert {:ok, report} = Next.run(run)
      rows = report.assigns[Lanes.Ack.Adapter]

      assert Enum.sum(Enum.map(rows, & &1.set)) == 5 * 4
      assert Enum.sum(Enum.map(rows, & &1.acknowledged)) == 5 * 4
      assert report.never_drawn == []
    end

    test "names a spec offered only in a lane and never drawn :never_chosen" do
      run = [model: JobModel, adapter: JobAdapter, seed: 1, max_steps: 0, max_plans: 2]

      assert {:ok, report} = Next.run(run ++ [lanes: 2, lane_steps: 1, yields: 1])
      assert [%{command: Rare, reason: :never_chosen}] = report.never_drawn
    end
  end

  describe "forked generation" do
    test "each lane is drawn from the state after the prefix, so two lane withdrawals can sum above the deposit" do
      found =
        Enum.find(1..200, fn seed ->
          plan = Next.plan(OnceModel, seed, @once)

          [
            %{command: %Deposit{amount: x}},
            %{command: %Withdraw{amount: a}},
            %{command: %Withdraw{amount: b}}
          ] =
            Enum.sort_by(plan.steps, & &1.key)

          a + b > x
        end)

      assert is_integer(found)
    end

    test "no lane step holds a placeholder of the other lane, and every placeholder resolves" do
      opts = [max_steps: 3, lanes: 2, lane_steps: 3, yields: 1]

      held =
        for seed <- 1..100,
            plan = Next.plan(Till.Model, seed, opts),
            %{key: {lane, slot}, command: %Till.Refund{payment: %Placeholder{step: from}}} <-
              plan.steps,
            lane > 0 do
          assert {seed, from_allowed?(from, lane, slot)} == {seed, true}
          from
        end

      assert Enum.any?(held, &match?({0, _}, &1))
      assert Enum.any?(held, &match?({lane, _} when lane > 0, &1))

      for seed <- 1..20 do
        journal = Next.plan(Till.Model, seed, opts).journal
        assert {:ok, _} = Next.replay(journal, model: Till.Model, adapter: Till.Adapter)
      end
    end
  end

  defp from_allowed?({0, _slot}, _lane, _at), do: true
  defp from_allowed?({lane, slot}, lane, at), do: slot < at
  defp from_allowed?(_from, _lane, _at), do: false

  describe "withdrawal in a lane" do
    test "lists the slot with its lane key and keeps its entries, schedule included" do
      opts = [max_steps: 1, lanes: 2, lane_steps: 1, yields: 1]
      plan = Next.plan(OnceModel, 1, opts)
      assert Map.has_key?(plan.journal.entries, {{1, 1}, :schedule, 1})

      # With the deposit gone, no withdrawal is offered in either lane.
      emptied = Map.put(plan.journal.entries, {{0, 1}, :pick}, {:empty})
      rebuilt = Next.plan(OnceModel, %{plan.journal | entries: emptied})

      assert rebuilt.steps == []

      assert rebuilt.withdrawn == [
               %{key: {1, 1}, command: Withdraw},
               %{key: {2, 1}, command: Withdraw}
             ]

      lane_one = fn entries ->
        Map.filter(entries, fn {key, _entry} -> elem(key, 0) == {1, 1} end)
      end

      assert lane_one.(rebuilt.journal.entries) == lane_one.(plan.journal.entries)
      assert Lanes.get(rebuilt, :schedule) == %{}
    end
  end

  describe "mint markers" do
    @retry [max_steps: 2, lanes: 2, lane_steps: 2, yields: 1]

    defp received(journal) do
      assert {:ok, _} =
               Next.replay(journal,
                 model: Retry.Model,
                 adapter: Retry.Adapter,
                 config: %{recorder: self()}
               )

      collect([])
    end

    defp collect(acc) do
      receive do
        {:retry_received, kind, fields} -> collect([{kind, fields} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # The step a retry's key was stamped for: the payment it repeats.
    defp stamp(%{command: %Retry.Again{original: %{key: %Mint{position: step}}}}), do: step
    defp stamp(_step), do: nil

    defp prefix_stamps(plan, lane) do
      plan |> in_lane(lane) |> Enum.map(&stamp/1) |> Enum.filter(&match?({0, _}, &1))
    end

    test "a marker read back from the prefix sends one value in both lanes" do
      seed =
        seed_where(Retry.Model, @retry, fn plan ->
          not MapSet.disjoint?(
            MapSet.new(prefix_stamps(plan, 1)),
            MapSet.new(prefix_stamps(plan, 2))
          )
        end)

      plan = Next.plan(Retry.Model, seed, @retry)
      received = received(plan.journal)

      pays = for {:pay, %{key: key}} <- received, do: key
      agains = for {:again, %{key: key}} <- received, do: key
      stamps = plan.steps |> Enum.map(&stamp/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      # One value per payment repeated, though a retry of it runs in each lane.
      assert Enum.all?(agains, &(&1 in pays))
      assert length(Enum.uniq(agains)) == length(stamps)
      assert length(agains) > length(stamps)
    end

    test "fresh markers drawn in two lane steps send different values" do
      seed =
        seed_where(Retry.Model, @retry, fn plan ->
          Enum.all?([1, 2], fn lane ->
            Enum.any?(in_lane(plan, lane), &match?(%{command: %Retry.Pay{}}, &1))
          end)
        end)

      plan = Next.plan(Retry.Model, seed, @retry)

      keys =
        for {:pay, %{key: key, request: request}} <- received(plan.journal),
            k <- [key, request],
            do: k

      assert length(keys) >= 4
      assert keys == Enum.uniq(keys)
    end
  end
end
