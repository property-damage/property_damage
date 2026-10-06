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
      if poison?(by, n), do: PropertyDamage.fail!("poisoned booking", n: n)
      :ok
    end

    defp poison?(by, n), do: by == "b" and n == 2
  end

  setup_all do
    {:ok, model: ActiveSet.define_model!(Module.concat(__MODULE__, PoisonModel), [Poisoned])}
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
