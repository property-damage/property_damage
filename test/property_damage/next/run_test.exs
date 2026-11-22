defmodule PropertyDamage.Next.RunTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal, Step}
  alias PropertyDamage.Next.Test.Scheme.{Adapter, CurrencyModel, Model, Refund, RefundedTotal}
  alias PropertyDamage.Next.Test.Terms

  defmodule Tripwires do
    @moduledoc false
    # Checks that always fail, to show when each kind of schedule fires.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: RefundedTotal
    def read_tripwire(_state, _command), do: PropertyDamage.fail!("a read ran")
  end

  defmodule SampledTripwire do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: 3
    def every_third(_state, _command_or_event), do: PropertyDamage.fail!("sampled")
  end

  defmodule TeardownCheck do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check at: :teardown
    def settled(_state, _command), do: true
  end

  defmodule EventCheck do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: :event
    def after_events(_state, _event), do: true
  end

  defmodule ReadTripwireModel do
    @moduledoc false
    use PropertyDamage.Next.Model
    alias PropertyDamage.Next.Test.Scheme.Payments

    def steps, do: Model.steps()
    def simulator, do: Model.simulator()
    def command_sequence_projection, do: Payments
    def check_projections, do: [Payments, Tripwires]
  end

  defmodule SampledTripwireModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps, do: Model.steps()
    def simulator, do: Model.simulator()
    def command_sequence_projection, do: Model.command_sequence_projection()
    def check_projections, do: [SampledTripwire]
  end

  defmodule TeardownCheckModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps, do: Model.steps()
    def simulator, do: Model.simulator()
    def command_sequence_projection, do: Model.command_sequence_projection()
    def check_projections, do: [TeardownCheck]
  end

  defmodule EventCheckModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    def steps, do: Model.steps()
    def simulator, do: Model.simulator()
    def command_sequence_projection, do: Model.command_sequence_projection()
    def check_projections, do: [EventCheck]
  end

  @seeds [1, 2, 3, 5, 8, 13, 21, 34]

  defp run(opts) do
    [model: Model, adapter: Adapter, max_steps: 20, max_plans: 10]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  defp replay(journal, opts) do
    Next.replay(journal, Keyword.merge([model: Model, adapter: Adapter, max_steps: 20], opts))
  end

  defp first_key(plan, module) do
    Enum.find_value(Terms.steps_of(plan), fn
      %Step{key: key, command: %^module{}} -> key
      _ -> nil
    end)
  end

  describe "the running example" do
    test "a run of the correct system passes on every seed" do
      for seed <- @seeds do
        assert {:ok, %{plans: 10}} = run(seed: seed), "seed #{seed} failed"
      end
    end

    test "a run of the correct system with currency refunds passes on every seed" do
      for seed <- @seeds do
        assert {:ok, %{plans: 10}} = run(model: CurrencyModel, seed: seed), "seed #{seed} failed"
      end
    end

    test "a seeded fault fails the run with the check's name" do
      for seed <- @seeds do
        assert {:error, %Failure{reason: {:check, :balance_matches, message}}} =
                 run(seed: seed, config: %{fault: :skip_credit})

        assert message =~ "the model expects"
      end
    end
  end

  describe "the failure" do
    test "plan 1 is the plan of the run's seed, and the run stops at the first failing step" do
      checked =
        for seed <- 1..10,
            plan = Next.plan(Model, seed, max_steps: 20),
            first_refund = first_key(plan, Refund),
            first_refund != nil do
          assert {:error, %Failure{} = failure} = run(seed: seed, config: %{fault: :skip_credit})

          assert failure.plan_number == 1
          assert Terms.steps_of(failure.plan) == plan.steps
          assert failure.step == first_refund
          assert failure.withdrawn == []
          assert Next.plan(Model, failure.journal, max_steps: 20).steps == plan.steps
          seed
        end

      assert checked != []
    end

    test "an adapter error is the reason, at the step that answered it" do
      assert {:error, %Failure{} = failure} = run(seed: 4, config: %{fault: :refund_error})

      assert failure.reason == {:adapter_error, :refund_unavailable}
      assert failure.step == first_key(failure.plan, Refund)
    end

    test "an adapter that raises gives the exception as the reason" do
      assert {:error, %Failure{reason: {:raise, %RuntimeError{} = error}} = failure} =
               run(seed: 4, config: %{fault: :refund_raises})

      assert Exception.message(error) == "the refund endpoint crashed"
      assert failure.step == first_key(failure.plan, Refund)
    end
  end

  describe "replay" do
    test "a failing run's journal rebuilds the identical plan and fails the same way at the same step" do
      for seed <- @seeds do
        assert {:error, %Failure{} = failure} = run(seed: seed, config: %{fault: :skip_credit})

        for journal <- [
              failure.journal,
              failure.journal |> Journal.to_binary() |> Journal.from_binary()
            ] do
          assert {:error, %Failure{} = again} = replay(journal, config: %{fault: :skip_credit})

          assert Terms.steps_of(again.plan) == Terms.steps_of(failure.plan)
          assert again.withdrawn == failure.withdrawn
          assert again.step == failure.step
          assert again.reason == failure.reason
        end
      end
    end

    test "a failure found after the first plan replays the same way" do
      failures =
        for seed <- 1..30,
            {:error, %Failure{} = failure} <-
              [run(seed: seed, max_steps: 2, max_plans: 50, config: %{fault: :skip_credit})],
            do: failure

      later = Enum.filter(failures, &(&1.plan_number > 1))
      assert later != []

      for failure <- later do
        assert {:error, %Failure{} = again} =
                 replay(failure.journal, max_steps: 2, config: %{fault: :skip_credit})

        assert Terms.steps_of(again.plan) == Terms.steps_of(failure.plan)
        assert again.step == failure.step
        assert again.reason == failure.reason
      end
    end

    test "a passing journal replays and passes" do
      journal = Next.plan(Model, 6, max_steps: 20).journal
      assert {:ok, _} = replay(journal, [])
    end
  end

  describe "check schedules" do
    test "a check scheduled on a command fires after the first step of that command" do
      assert {:error, %Failure{reason: {:check, :read_tripwire, _}} = failure} =
               run(model: ReadTripwireModel, seed: 2)

      assert failure.step == first_key(failure.plan, RefundedTotal)
    end

    test "a check sampled every N fires during the run, not at the first step" do
      assert {:error, %Failure{reason: {:check, :every_third, _}} = failure} =
               run(model: SampledTripwireModel, seed: 2)

      assert failure.step != {0, 1}
    end

    test "any other check form is refused when the run loads the model" do
      for model <- [TeardownCheckModel, EventCheckModel] do
        assert Exception.message(Terms.raised(fn -> run(model: model, seed: 1) end)) =~
                 "not supported by this engine yet"
      end
    end
  end
end
