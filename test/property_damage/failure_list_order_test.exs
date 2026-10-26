defmodule PropertyDamage.FailureListOrderTest do
  # One rule orders a run's failures, whether or not a target was retired:
  # first in root order, then in target order, and within one root in one
  # target a check that failed while the root was stepped comes before the
  # comparison failure found at that root's boundary. Every failure is
  # listed once, and a comparison failure that loses the primary place to
  # a recorded check is still listed among the others.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Options, Scheduler}
  alias PropertyDamage.Test.{ActiveSet, VariantSupport}
  alias PropertyDamage.Test.ActiveSet.{Book, Booked}

  defmodule Poisoned do
    @moduledoc false
    # Target "b" books a poisoned command 2: its check fails while root 2 is
    # stepped, and its observation differs from the reference's from root 2 on.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{poisoned: false}

    @impl true
    def apply(state, %Booked{n: n, by: by}),
      do: %{state | poisoned: state.poisoned or poison?(by, n)}

    def apply(state, _event), do: state

    @compare every: 1
    def poisoned(state, _root), do: state.poisoned

    @check every: Booked
    def assert_no_poison(_state, %Booked{n: n, by: by}) do
      not poison?(by, n) or PropertyDamage.fail!("poisoned booking", n: n)
    end

    defp poison?(by, n), do: by == "b" and n == 2
  end

  defmodule Early do
    @moduledoc false
    # Targets "b" and "c" book a poisoned command 0: the check fails while
    # root 0 is stepped, and the observation, compared only at the final
    # boundary, differs from the reference's there.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{poisoned: false}

    @impl true
    def apply(state, %Booked{n: n, by: by}),
      do: %{state | poisoned: state.poisoned or poison?(by, n)}

    def apply(state, _event), do: state

    @compare every: :end
    def poisoned(state, _root), do: state.poisoned

    @check every: Booked
    def assert_no_early_poison(_state, %Booked{n: n, by: by}) do
      not poison?(by, n) or PropertyDamage.fail!("poisoned booking", n: n)
    end

    defp poison?(by, n), do: by in ["b", "c"] and n == 0
  end

  defmodule Twice do
    @moduledoc false
    # The reference "a" books a poisoned command 0 and target "b" books
    # poisoned commands 1 and 3: each check fails while that root is
    # stepped, and the observation is compared only at the final boundary.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{poisoned: []}

    @impl true
    def apply(state, %Booked{n: n, by: by}) do
      if poison?(by, n), do: %{state | poisoned: state.poisoned ++ [n]}, else: state
    end

    def apply(state, _event), do: state

    @compare every: :end
    def poisoned(state, _root), do: state.poisoned

    @check every: Booked
    def assert_no_twice_poison(_state, %Booked{n: n, by: by}) do
      not poison?(by, n) or PropertyDamage.fail!("poisoned booking", n: n)
    end

    defp poison?(by, n), do: {by, n} in [{"a", 0}, {"b", 1}, {"b", 3}]
  end

  setup_all do
    {:ok,
     model: ActiveSet.define_model!(Module.concat(__MODULE__, PoisonModel), [Poisoned]),
     early_model: ActiveSet.define_model!(Module.concat(__MODULE__, EarlyModel), [Early]),
     twice_model: ActiveSet.define_model!(Module.concat(__MODULE__, TwiceModel), [Twice])}
  end

  setup do
    {:ok, recorder: VariantSupport.start_recorder()}
  end

  defp schedule(ctx, configs, extra) do
    {:ok, targets} =
      configs
      |> Enum.map(fn {name, config} -> ActiveSet.target(name, ctx.recorder, config) end)
      |> Options.validate_targets()

    {:ok, run} =
      [
        model: ctx.model,
        targets: targets,
        commands: for(n <- 0..4, do: %Book{n: n}),
        seed: 1,
        run_number: 0,
        run_nonce: 1,
        concurrency: :serial,
        compare: [converge_within: 100]
      ]
      |> Keyword.merge(extra)
      |> Scheduler.run()

    run
  end

  defp summary(failure),
    do: {failure.variant.name, failure.root, failure.kind, Failure.name(failure.reason)}

  defp others(run), do: Enum.map(run.other_failures, &summary/1)

  @check_b {"b", 2, :check_failed, :no_poison}
  @diverged_b {"b", 2, :diverged, {Poisoned, :poisoned}}

  describe "a recorded check and a divergence in one target at one root" do
    test "without a retirement the check is primary and the divergence is listed", ctx do
      run = schedule(ctx, [{"a", %{}}, {"b", %{}}], check_mode: :record)

      assert summary(run.failure) == @check_b
      assert others(run) == [@diverged_b]
    end

    test "with a retirement at that root the check is primary, then the divergence, then the retirement",
         ctx do
      configs = [{"a", %{}}, {"b", %{}}, {"c", %{fail: %{2 => :error}}}]
      run = schedule(ctx, configs, check_mode: :record)

      assert summary(run.failure) == @check_b
      assert others(run) == [@diverged_b, {"c", 2, :execution_failed, nil}]
    end

    test "with a retirement at an earlier root the check is listed before the divergence", ctx do
      configs = [{"a", %{}}, {"b", %{}}, {"c", %{fail: %{0 => :error}}}]
      run = schedule(ctx, configs, check_mode: :record)

      assert summary(run.failure) == {"c", 0, :execution_failed, nil}
      assert others(run) == [@check_b, @diverged_b]
    end
  end

  describe "a check recorded at an earlier root" do
    @check_b0 {"b", 0, :check_failed, :no_early_poison}

    test "does not skip the comparison at the final boundary", ctx do
      run = schedule(ctx, [{"a", %{}}, {"b", %{}}], check_mode: :record, model: ctx.early_model)

      assert summary(run.failure) == @check_b0
      assert others(run) == [{"b", 4, :diverged, {Early, :poisoned}}]
    end

    test "in a target retired later is listed with that target's retirement", ctx do
      configs = [{"a", %{}}, {"b", %{}}, {"c", %{fail: %{2 => :error}}}]
      run = schedule(ctx, configs, check_mode: :record, model: ctx.early_model)

      assert summary(run.failure) == @check_b0

      assert Enum.filter(others(run), &(elem(&1, 0) == "c")) == [
               {"c", 0, :check_failed, :no_early_poison},
               {"c", 2, :execution_failed, nil}
             ]
    end
  end

  describe "a target that halts after recording checks" do
    defp all(run), do: Enum.map([run.failure | run.other_failures], &summary/1)

    test "when retired lists the first check it recorded, once", ctx do
      configs = [{"a", %{}}, {"b", %{fail: %{4 => :error}}}]
      run = schedule(ctx, configs, check_mode: :record, model: ctx.twice_model)

      assert Enum.filter(all(run), &match?({"b", _, :check_failed, _}, &1)) == [
               {"b", 1, :check_failed, :no_twice_poison}
             ]

      assert {"b", 4, :execution_failed, nil} in all(run)
      assert Enum.uniq(all(run)) == all(run)
    end

    test "when it is the reference keeps the check it recorded beside its halt", ctx do
      configs = [{"a", %{fail: %{3 => :error}}}, {"b", %{}}]
      run = schedule(ctx, configs, check_mode: :record, model: ctx.twice_model)

      assert all(run) == [
               {"a", 0, :check_failed, :no_twice_poison},
               {"b", 1, :check_failed, :no_twice_poison},
               {"a", 3, :execution_failed, nil}
             ]
    end
  end

  describe "a halting failure in a target that stays in the run" do
    test "after a retirement it is listed once", ctx do
      configs = [{"a", %{}}, {"b", %{}}, {"c", %{fail: %{1 => :error}}}]
      run = schedule(ctx, configs, check_mode: :halt)

      assert summary(run.failure) == {"c", 1, :execution_failed, nil}
      assert others(run) == [@check_b]
    end

    test "without a retirement it is the primary failure and nothing else is listed", ctx do
      run = schedule(ctx, [{"a", %{}}, {"b", %{}}], check_mode: :halt)

      assert summary(run.failure) == @check_b
      assert others(run) == []
    end
  end
end
