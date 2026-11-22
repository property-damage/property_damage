# Two more scheme models for the new engine, ports of the default corpus
# directory's models of the same names. They reuse the commands, projection,
# simulator and adapter of `scheme_model.exs`.

Code.require_file("scheme_model.exs", __DIR__)

defmodule Corpus.Next.Scheme.DepthModel do
  @moduledoc """
  Pays small amounts and refunds them mostly one unit at a time, so a payment
  can take several refunds in one plan.

  A refund targets the first payment, in the order they were made, that still
  has a balance. Four draws in five refund 1; the rest refund between 1 and
  the balance.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Pay, Projection, Refund}
  alias PropertyDamage.Next.{Command, Gen, StepSpec}

  def steps do
    [pay, refund] =
      StepSpec.normalize([
        {Pay, weight: 1},
        {Refund, weight: 4, when: &Projection.refundable?/1}
      ])

    [
      StepSpec.put_command_field(pay, :amount, Gen.integer(1..10)),
      StepSpec.update_command(refund, &mostly_one/2)
    ]
  end

  # The amount depends on the drawn payment's balance and mixes two
  # generators by weight, which no PD description can say, so it is a
  # StreamData generator returned by a from/2 function.
  defp mostly_one(fields, state) do
    amount =
      Command.from(:payment_id, fn id ->
        balance = state.payments[id].expected
        Gen.frequency([{4, Gen.constant(1)}, {1, Gen.integer(1..balance)}])
      end)

    Map.put(fields, :amount, amount)
  end

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Simulator
end

defmodule Corpus.Next.Scheme.RangeModel do
  @moduledoc """
  Pays and refunds with the refund amount drawn uniformly from 1 up to the
  payment's balance, so a first refund may be anything up to the whole
  payment. No amount is favored.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Pay, Projection, Refund}
  alias PropertyDamage.Next.StepSpec

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Projection.refundable?/1}
    ])
  end

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Simulator
end
