# The split refund model, written for the new engine. It drives the same
# system as the other scheme entries, `Corpus.Scheme`, with their commands,
# simulator and adapter, and states a second way to run a refund: as two
# refunds of the same payment whose amounts add up to the first one.
#
# Nothing checks a balance on one execution, and the projection that predicts
# the balances has no check. The model only records the balances the scheme
# reported and compares them between the two executions after every step, so
# a scheme that credits a split refund differently from the same refund made
# once shows up as a divergence and nowhere else.

Code.require_file("scheme_model.exs", __DIR__)

defmodule Corpus.Next.Scheme.Expected do
  @moduledoc """
  What each payment's balance should be, folded from the predicted events, in
  the order the payments were made. It has the state shape of
  `Corpus.Next.Scheme.Projection` and none of its checks, so nothing compares
  a reported balance with the expected one on a single execution.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}

  @impl true
  def init, do: %{payments: %{}, order: []}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}),
    do: %{
      state
      | payments: Map.put(state.payments, id, %{expected: amount}),
        order: state.order ++ [id]
    }

  def apply(state, %Refunded{payment_id: id, amount: amount}),
    do: update_in(state, [:payments, id], &%{expected: &1.expected - amount})

  def apply(state, _event), do: state
end

defmodule Corpus.Next.Scheme.Reported do
  @moduledoc """
  The balance of each payment as the scheme reported it, in the order the
  payments were made. Its observation holds balances only, never payment ids,
  because each execution has a scheme of its own and mints its own ids.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}

  @impl true
  def init, do: %{order: [], balances: %{}}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}),
    do: %{state | order: state.order ++ [id], balances: Map.put(state.balances, id, amount)}

  def apply(state, %Refunded{payment_id: id, balance: balance}),
    do: %{state | balances: Map.put(state.balances, id, balance)}

  def apply(state, _event), do: state

  @compare every: 1
  def balances(state, _root), do: Enum.map(state.order, &Map.fetch!(state.balances, &1))
end

defmodule Corpus.Next.Scheme.SplitPaths do
  @moduledoc """
  The paths of a refund. A refund of 2 or more runs as itself, or as two
  refunds of the same payment: a first part drawn from 1 up to one less than
  the amount, then the rest. A refund of 1 has no other path.
  """

  alias Corpus.Next.Scheme.Refund
  alias PropertyDamage.Next.Gen

  def refund_paths(%Refund{amount: amount} = refund, _state)
      when is_integer(amount) and amount >= 2 do
    [
      [refund],
      {%{amount: Gen.integer(1..(amount - 1))},
       fn %{amount: part} ->
         [%{refund | amount: part}, %{refund | amount: amount - part}]
       end}
    ]
  end

  def refund_paths(%Refund{} = refund, _state), do: [[refund]]
end

defmodule Corpus.Next.Scheme.SplitModel do
  @moduledoc """
  Pays and refunds, with every response delivered. A refund amount is drawn
  uniformly from 1 up to the payment's balance, without the boost toward the
  whole balance that `Corpus.Next.Scheme.RefundModel` gives: the bug needs a
  second refund of a payment, and a whole-balance refund leaves nothing to
  split. Each refund can run as itself or as two refunds (see
  `Corpus.Next.Scheme.SplitPaths`).

  The model checks no balance. Its one observation, the balances the scheme
  reported, is compared between the two executions of each plan.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Expected, Pay, Projection, Refund, Reported, SplitPaths}
  alias PropertyDamage.Next.StepSpec

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Projection.refundable?/1}
    ])
  end

  def command_sequence_projection, do: Expected
  def check_projections, do: [Reported]
  def simulator, do: Corpus.Next.Scheme.Simulator
  def expansions, do: [{Refund, &SplitPaths.refund_paths/2}]
end

defmodule Corpus.Next.Scheme.UnsplitModel do
  @moduledoc """
  The split model without `expansions/0`: the same steps and projections, so
  each plan runs once and nothing is compared. It is the control for the
  split refund entry.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.SplitModel

  def steps, do: SplitModel.steps()
  def command_sequence_projection, do: SplitModel.command_sequence_projection()
  def simulator, do: SplitModel.simulator()
end
