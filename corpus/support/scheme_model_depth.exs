defmodule Corpus.Scheme.DepthModel do
  @moduledoc """
  Pays small amounts and refunds them mostly one unit at a time, so a payment
  can take several refunds in one plan.

  A refund targets the first payment (in key order) that still has a balance.
  Four draws in five refund 1; the rest refund between 1 and the balance.
  """
  use PropertyDamage.Model

  alias Corpus.Scheme.{Pay, Projection, Refund}

  @impl true
  def commands do
    [
      {Pay, weight: 1, overrides: fn _state -> %{amount: StreamData.integer(1..10)} end},
      {Refund, weight: 4, when: &Projection.refundable?/1, overrides: &refund_overrides/1}
    ]
  end

  defp refund_overrides(state) do
    {id, %{expected: balance}} = first_refundable(state)

    %{
      payment_id: id,
      amount:
        StreamData.frequency([
          {4, StreamData.constant(1)},
          {1, StreamData.integer(1..balance)}
        ]),
      lose_response: false
    }
  end

  defp first_refundable(state) do
    state.payments
    |> Enum.filter(fn {_id, p} -> p.expected > 0 end)
    |> Enum.min_by(&elem(&1, 0))
  end

  @impl true
  def command_sequence_projection, do: Projection

  @impl true
  def check_projections, do: [Projection]

  @impl true
  def simulator, do: Corpus.Scheme.Simulator
end

defmodule Corpus.Scheme.RangeModel do
  @moduledoc """
  Pays and refunds with the refund amount drawn uniformly from 1 up to the
  payment's balance, so a first refund may be anything up to the whole
  payment. No amount is favored.
  """
  use PropertyDamage.Model

  alias Corpus.Scheme.{Pay, Projection, Refund}

  @impl true
  def commands do
    [
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Projection.refundable?/1, overrides: &refund_overrides/1}
    ]
  end

  defp refund_overrides(state) do
    {id, %{expected: balance}} =
      state.payments
      |> Enum.filter(fn {_id, p} -> p.expected > 0 end)
      |> Enum.min_by(&elem(&1, 0))

    %{payment_id: id, amount: StreamData.integer(1..balance), lose_response: false}
  end

  @impl true
  def command_sequence_projection, do: Projection

  @impl true
  def check_projections, do: [Projection]

  @impl true
  def simulator, do: Corpus.Scheme.Simulator
end
