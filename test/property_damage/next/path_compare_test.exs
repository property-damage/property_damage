defmodule PropertyDamage.Next.PathCompareTest do
  # After each step, every `@compare every: 1` observation is evaluated on
  # the reference's state and on the variant's, and the first pair that
  # disagrees fails the run with `{:diverged, name, step, reference,
  # variant}` at that step. Agreement is `==`, or the verdict of the
  # observation's `using:` relation.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Failure
  alias PropertyDamage.Next.Test.Paths
  alias PropertyDamage.Next.Test.Paths.{Recorded, Refund, Settle, SettleModel, SplitModel}

  @bug %{bug: :short_second_refund}

  defmodule Folded do
    @moduledoc false
    # The fold of the totals observation, shared by the projections below.
    alias PropertyDamage.Next.Test.Paths.Totals

    defmacro __using__(_opts) do
      quote do
        use PropertyDamage.Model.Projection

        @impl true
        def init, do: Totals.init()

        @impl true
        def apply(state, event), do: Totals.apply(state, event)
      end
    end
  end

  defmodule PaidOnly do
    @moduledoc false
    # The totals, judged equal when the paid totals are.
    use PropertyDamage.Next.PathCompareTest.Folded

    @compare every: 1, using: :same_paid
    def totals(state, _root), do: state

    defp same_paid(reference, variant), do: reference.paid == variant.paid
  end

  defmodule RootSeen do
    @moduledoc false
    # The step's command as the observation receives it; raises if any PD
    # term is left in it.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Next.Test.Leak

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @compare every: 1
    def root_seen(_state, root) do
      case Leak.find(root) do
        [] -> root
        found -> raise "the observation received PD terms: #{inspect(found)}"
      end
    end
  end

  defmodule Declared do
    @moduledoc false
    # Two observations of the same totals, declared in this order.
    use PropertyDamage.Next.PathCompareTest.Folded

    @compare every: 1
    def zeta(state, _root), do: state

    @compare every: 1
    def alpha(state, _root), do: state
  end

  defmodule Listed do
    @moduledoc false
    use PropertyDamage.Next.PathCompareTest.Folded

    @compare every: 1
    def middle(state, _root), do: state
  end

  defmodule Raising do
    @moduledoc false
    use PropertyDamage.Next.PathCompareTest.Folded

    @compare every: 1
    def boom(state, _root) do
      if state.refunded > 0, do: raise("no refunds expected"), else: state
    end
  end

  defmodule Pending do
    @moduledoc false
    use PropertyDamage.Next.PathCompareTest.Folded

    @compare every: 1
    def waiting(state, _root), do: {:pending, state.refunded}
  end

  # A model with the refund model's specs and paths and the given check projections.
  for {name, projections} <- [
        TolerantModel: [PaidOnly],
        RootModel: [RootSeen],
        DeclaredModel: [Declared],
        ListedModel: [Listed, Declared],
        RaisingModel: [Raising],
        PendingModel: [Pending]
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.Test.Paths.{Expansions, SplitModel, State}

      @projections projections
      def steps, do: SplitModel.steps()
      def simulator, do: SplitModel.simulator()
      def command_sequence_projection, do: State
      def check_projections, do: @projections
      def expansions, do: Expansions.refunds()
    end
  end

  defp run(model, seed, opts \\ []) do
    [
      model: model,
      adapter: Paths.Adapter,
      seed: seed,
      max_steps: 6,
      max_plans: 100,
      shrink: false,
      config: %{}
    ]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  # The totals each execution observed after each executed step of `plan`,
  # from the calls the adapter reported: the reference's call for the step,
  # and the variant's calls for the commands of the step's path.
  defp totals_per_step(plan, reference, variant) do
    executed = Enum.take(plan.steps, length(reference.calls))

    executed
    |> Enum.with_index(1)
    |> Enum.map(fn {step, count} ->
      commands =
        executed
        |> Enum.take(count)
        |> Enum.map(&length(Recorded.path_commands(&1)))
        |> Enum.sum()

      {step.key, Recorded.totals(Enum.take(reference.calls, count)),
       Recorded.totals(Enum.take(variant.calls, commands))}
    end)
  end

  describe "a path that credits less than the step as drawn" do
    test "fails at the earliest step where the totals differ, with the values each execution observed" do
      not_last =
        for seed <- 1..6 do
          assert {:error, %Failure{} = failure} =
                   run(SplitModel, seed, config: Map.put(@bug, :recorder, self()))

          assert {:diverged, :totals, step, reference_value, variant_value} = failure.reason
          assert failure.step == step
          assert reference_value != variant_value

          # The failing plan is the last one executed.
          [reference, variant] = Enum.take(Recorded.executions(), -2)
          assert reference_value == Recorded.totals(reference.calls)
          assert variant_value == Recorded.totals(variant.calls)

          rows = totals_per_step(failure.plan, reference, variant)
          {first_differing, _, _} = Enum.find(rows, fn {_key, r, v} -> r != v end)
          assert step == first_differing
          assert step == rows |> List.last() |> elem(0)

          step != List.last(failure.plan.steps).key
        end

      assert Enum.any?(not_last), "every divergence fell on the plan's last step"
    end

    test "that shows only after a later step fails at that later step" do
      for seed <- 1..6 do
        assert {:error, %Failure{} = failure} = run(SettleModel, seed, config: @bug)

        assert {:diverged, :settled, step, reference_value, variant_value} = failure.reason
        assert failure.step == step
        assert reference_value > variant_value

        steps = failure.plan.steps

        split =
          Enum.find_index(steps, &(match?(%Refund{}, &1.command) and Recorded.pick(&1) == 1))

        assert split != nil

        settle =
          steps
          |> Enum.drop(split + 1)
          |> Enum.find(&match?(%Settle{}, &1.command))

        assert step == settle.key
      end
    end

    test "passes when a using: relation accepts the difference" do
      assert {:error, %Failure{reason: {:diverged, :totals, _, _, _}}} =
               run(SplitModel, 1, max_plans: 30, config: @bug)

      assert {:ok, %{plans: 30}} = run(__MODULE__.TolerantModel, 1, max_plans: 30, config: @bug)
    end
  end

  describe "paths that all mean the same" do
    test "pass" do
      for model <- [SplitModel, SettleModel] do
        assert {:ok, %{plans: 30}} = run(model, 1, max_plans: 30)
      end
    end

    test "the observation receives the step's command as drawn, made concrete, in both executions" do
      assert {:ok, %{plans: 30}} = run(__MODULE__.RootModel, 1, max_plans: 30)
    end
  end

  describe "which observation names the failure" do
    test "the first in declaration order of its projection" do
      assert {:error, %Failure{reason: {:diverged, :zeta, _, _, _}}} =
               run(__MODULE__.DeclaredModel, 1, config: @bug)
    end

    test "the first projection in the order the model lists them" do
      assert {:error, %Failure{reason: {:diverged, :middle, _, _, _}}} =
               run(__MODULE__.ListedModel, 1, config: @bug)
    end
  end

  describe "an observation's own answer" do
    test "a raise fails the run at the step with the exception" do
      assert {:error, %Failure{} = failure} = run(__MODULE__.RaisingModel, 1)

      assert {:raise, %RuntimeError{message: "no refunds expected"}} = failure.reason
      first_refund = Enum.find(failure.plan.steps, &match?(%Refund{}, &1.command))
      assert failure.step == first_refund.key
    end

    test "a pending value is compared as a value, without waiting" do
      assert {:ok, %{plans: 20}} = run(__MODULE__.PendingModel, 1, max_plans: 20)

      assert {:error, %Failure{} = failure} = run(__MODULE__.PendingModel, 1, config: @bug)

      assert {:diverged, :waiting, _step, {:pending, reference}, {:pending, variant}} =
               failure.reason

      assert reference > variant
    end
  end
end
