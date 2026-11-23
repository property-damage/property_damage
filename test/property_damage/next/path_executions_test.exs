defmodule PropertyDamage.Next.PathExecutionsTest do
  # A model that states paths runs each plan twice, against two fresh setups
  # of the one adapter: the reference runs every step as drawn, and the
  # variant runs the commands of the path picked for each step, each with
  # the step's assigns. A model without paths runs each plan once. A failure
  # of the variant alone fails the run at its step with its own reason.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Failure
  alias PropertyDamage.Next.Test.Paths

  alias PropertyDamage.Next.Test.Paths.{
    AssignModel,
    Pay,
    Peek,
    PeekCheckModel,
    PlainModel,
    QuietModel,
    Recorded,
    Token
  }

  @max_steps 6

  defmodule TokenModel do
    @moduledoc false
    # One command holding a minted value, listed with a path that runs it
    # twice.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures, as: F
    alias PropertyDamage.Next.Test.Paths.{Expansions, Token}

    def steps, do: StepSpec.normalize([Token])
    def simulator, do: F.NullSimulator
    def command_sequence_projection, do: F.EmptyProjection
    def expansions, do: [{Token, &Expansions.token_paths/2}]
  end

  defp run(model, seed, opts \\ []) do
    [
      model: model,
      adapter: Paths.Adapter,
      seed: seed,
      max_steps: @max_steps,
      max_plans: 1,
      config: %{recorder: self(), ack: true}
    ]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  defp calls(execution),
    do: Enum.map(execution.calls, fn {command, assigns, _} -> {command, assigns} end)

  # What each execution of `plan` should receive: the reference every step
  # as drawn, the variant each command of each step's path; both with the
  # step's assigns.
  defp expected(plan) do
    reference = for step <- plan.steps, do: {Recorded.concrete(step.command, plan), step.assigns}

    variant =
      for step <- plan.steps,
          command <- Recorded.path_commands(step),
          do: {Recorded.concrete(command, plan), step.assigns}

    {reference, variant}
  end

  describe "a model with paths" do
    test "sets up and tears down two executions per plan, each a distinct context" do
      assert {:ok, %{plans: 3}} = run(AssignModel, 1, max_plans: 3)

      executions = Recorded.executions()
      assert length(executions) == 2 * 3
      assert executions |> Enum.map(& &1.instance) |> Enum.uniq() |> length() == 6
      assert Enum.all?(executions, &(&1.teardown != nil))
    end

    test "gives the reference every step as drawn and the variant each command of the picked path, with the step's assigns, in order" do
      checked =
        for seed <- 1..10 do
          assert {:ok, _report} = run(AssignModel, seed)
          plan = Next.plan(AssignModel, seed, max_steps: @max_steps)
          assert [reference, variant] = Recorded.executions()

          {expected_reference, expected_variant} = expected(plan)
          assert calls(reference) == expected_reference
          assert calls(variant) == expected_variant

          expected_reference != expected_variant
        end

      assert Enum.any?(checked), "no seed picked a path other than the plain one"
    end

    test "keeps the two executions apart: each system runs only its own commands" do
      checked =
        for seed <- 1..10 do
          assert {:ok, _report} = run(AssignModel, seed)
          plan = Next.plan(AssignModel, seed, max_steps: @max_steps)
          assert [reference, variant] = Recorded.executions()

          path_length = plan.steps |> Enum.map(&length(Recorded.path_commands(&1))) |> Enum.sum()
          assert reference.teardown == length(plan.steps)
          assert variant.teardown == path_length

          path_length != length(plan.steps)
        end

      assert Enum.any?(checked), "no seed ran a longer path"
    end

    test "runs the steps in lockstep: the reference's step, then the variant's commands for it" do
      assert {:ok, _report} = run(AssignModel, 4)
      plan = Next.plan(AssignModel, 4, max_steps: @max_steps)
      messages = Recorded.messages()

      [{:paths_setup, reference}, {:paths_setup, variant} | _] = messages

      order =
        for {:paths_executed, instance, _command, _assigns, _result} <- messages do
          if instance == reference, do: :reference, else: :variant
        end

      expected =
        Enum.flat_map(plan.steps, fn step ->
          [:reference | List.duplicate(:variant, length(Recorded.path_commands(step)))]
        end)

      assert variant != reference
      assert order == expected
    end

    test "tears down both executions of every plan after a failure" do
      assert {:error, %Failure{plan_number: number}} =
               run(QuietModel, 2,
                 max_plans: 100,
                 shrink: false,
                 config: %{recorder: self(), peek_error: true}
               )

      executions = Recorded.executions()
      assert length(executions) == 2 * number
      assert Enum.all?(executions, &(&1.teardown != nil))
    end

    test "fails the run with no step when the setup of either execution fails, and tears down the one set up" do
      for failing <- [1, 2] do
        counter = :counters.new(1, [])

        assert {:error, %Failure{step: nil, reason: {:adapter_error, :no_system}}} =
                 run(QuietModel, 1,
                   shrink: false,
                   config: %{recorder: self(), failing_setup: {counter, failing}}
                 )

        executions = Recorded.executions()
        if failing == 2, do: assert(length(executions) == 1)
        assert Enum.all?(executions, &(&1.teardown != nil))
      end
    end

    test "gives each execution its own minted values" do
      assert {:ok, _report} = run(TokenModel, 1, max_steps: 3)
      assert [reference, variant] = Recorded.executions()

      tokens = fn execution ->
        MapSet.new(execution.calls, fn {%Token{token: t}, _, _} -> t end)
      end

      assert MapSet.size(tokens.(reference)) == 3
      assert MapSet.disjoint?(tokens.(reference), tokens.(variant))
    end
  end

  describe "a model without paths" do
    test "runs each plan once, as before" do
      assert {:ok, %{plans: 3}} = run(PlainModel, 1, max_plans: 3)

      executions = Recorded.executions()
      assert length(executions) == 3
      assert Enum.all?(executions, &(&1.teardown != nil))
    end

    test "gives the one execution every step as drawn" do
      assert {:ok, _report} = run(PlainModel, 5)
      plan = Next.plan(PlainModel, 5, max_steps: @max_steps)
      assert [execution] = Recorded.executions()

      assert calls(execution) ==
               Enum.map(plan.steps, &{Recorded.concrete(&1.command, plan), &1.assigns})
    end
  end

  describe "a failure of the variant alone" do
    # Only a payment's second path runs a read, so the reference never does.
    defp first_peek_step(plan) do
      Enum.find(plan.steps, &(match?(%Pay{}, &1.command) and Recorded.pick(&1) == 1))
    end

    test "an adapter error on a finer command fails the run at that step with that reason" do
      for seed <- 1..5 do
        assert {:error, %Failure{} = failure} =
                 run(QuietModel, seed,
                   max_plans: 50,
                   shrink: false,
                   config: %{recorder: self(), peek_error: true}
                 )

        step = first_peek_step(failure.plan)
        assert step != nil
        assert failure.step == step.key
        assert failure.reason == {:adapter_error, :peek_failed}
        assert Enum.any?(Recorded.path_commands(step), &match?(%Peek{}, &1))

        # The failing plan is the last one executed; its reference ran every
        # step up to the failing one, and each passed.
        [reference, _variant] = Enum.take(Recorded.executions(), -2)
        through = Enum.take_while(failure.plan.steps, &(&1.key != step.key)) ++ [step]
        assert length(reference.calls) == length(through)
        assert Enum.all?(reference.calls, &match?({_, _, {:ok, _}}, &1))
      end
    end

    test "a failing check on a finer command fails the run at that step with that check" do
      for seed <- 1..5 do
        assert {:error, %Failure{} = failure} =
                 run(PeekCheckModel, seed, max_plans: 50, shrink: false, config: %{})

        step = first_peek_step(failure.plan)
        assert step != nil
        assert failure.step == step.key
        assert {:check, :no_peek, message} = failure.reason
        assert message =~ "a read ran"
      end
    end
  end
end
