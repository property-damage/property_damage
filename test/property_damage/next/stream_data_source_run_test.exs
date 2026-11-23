defmodule PropertyDamage.Next.StreamDataSourceRunTest do
  # Runs, shrinks and replays on the engine that draws every generator
  # through StreamData from a recording source.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data

  import PropertyDamage.Next.Test.OwnLog, only: [with_own_log: 1]

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.StreamDataSource
  alias PropertyDamage.Next.{Failure, Journal}
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Shrink.{Amount, Stock, Till}

  defmodule Charge do
    @moduledoc false
    # A dependent field whose from/2 function returns a StreamData
    # generator: the larger the amount, the likelier a large fee.
    use PropertyDamage.Next.Command

    defstruct [:amount, :fee]

    def generator(_state, _opts) do
      %{
        amount: integer(1..10),
        fee:
          from(:amount, fn amount ->
            frequency([{amount, constant(:large)}, {1, constant(:none)}])
          end)
      }
    end
  end

  defmodule ChargeModel do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures.{EmptyProjection, NullSimulator}

    def steps, do: StepSpec.normalize([Charge])
    def simulator, do: NullSimulator
    def command_sequence_projection, do: EmptyProjection
  end

  @engine [engine: StreamDataSource]

  defp run(opts), do: Next.run(Keyword.merge([max_plans: 2_000] ++ @engine, opts))

  # Replays a final journal, as it is and after a save and a load: the plan
  # and the failure come back unchanged.
  defp assert_replays(%Failure{} = failure, opts) do
    for journal <- [
          failure.journal,
          failure.journal |> Journal.to_binary() |> Journal.from_binary()
        ] do
      assert {:error, %Failure{} = again} = Next.replay(journal, opts ++ @engine)
      assert again.plan.steps == failure.plan.steps
      assert again.plan.journal == failure.journal
      assert again.step == failure.step
      assert again.reason == failure.reason
    end
  end

  test "a dependent StreamData generator runs with no warning, no raise and no kept site" do
    fails? = fn %Charge{fee: fee}, _earlier -> fee == :large end

    for mode <- [:warn, :raise], seed <- 1..3 do
      {result, log} =
        with_own_log(fn ->
          run(
            model: ChargeModel,
            adapter: Shrink.Adapter,
            seed: seed,
            max_steps: 3,
            dependent_stream_data: mode,
            config: %{fails?: fails?}
          )
        end)

      assert {:error, %Failure{kept: []} = failure} = result
      assert log == ""
      assert [%Charge{fee: :large}] = Enum.map(failure.plan.steps, & &1.command)

      assert Enum.all?(
               Map.values(failure.journal.entries),
               &(elem(&1, 0) in [:pick, :empty, :source])
             )
    end
  end

  test "the shrinker lowers each recorded position: an amount of at least 37 shrinks to exactly 37" do
    fails? = fn %Amount{amount: amount}, _earlier -> amount >= 37 end

    firsts =
      for seed <- 1..6 do
        assert {:error, %Failure{} = failure} =
                 run(
                   model: Shrink.AmountModel,
                   adapter: Shrink.Adapter,
                   seed: seed,
                   max_steps: 1,
                   config: %{fails?: fails?}
                 )

        assert [%Amount{amount: 37}] = Enum.map(failure.plan.steps, & &1.command)
        [%Amount{amount: first}] = Enum.map(failure.original.plan.steps, & &1.command)
        first
      end

    assert Enum.any?(firsts, &(&1 > 37))
  end

  test "every final journal of a run on this engine replays to the identical plan" do
    fixtures = [
      {Shrink.AmountModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> c.amount >= 37 end}},
      {Shrink.SplitModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> c.rest == 101 - c.cut end}},
      {Shrink.NoteModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> byte_size(c.text) >= 2 end}},
      {Till.Model, Till.Adapter, 14, %{bug: true}},
      {Stock.Model, Shrink.Adapter, 8,
       %{fails?: fn c, _ -> match?(%Stock.Take{count: n} when n >= 3, c) end}},
      {ChargeModel, Shrink.Adapter, 3, %{fails?: fn c, _ -> c.fee == :large end}}
    ]

    checked =
      for {model, adapter, max_steps, config} <- fixtures,
          seed <- 1..3,
          {:error, %Failure{} = failure} <- [
            run(model: model, adapter: adapter, seed: seed, max_steps: max_steps, config: config)
          ] do
        assert_replays(failure, model: model, adapter: adapter, config: config)
        model
      end

    assert checked |> Enum.uniq() |> length() == length(fixtures)
  end
end
