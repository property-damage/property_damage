# The lost full refund model, written for the new engine. It drives the same
# system as the entry in the default corpus directory, `Corpus.Scheme`, and
# ports that entry's refund model: pay 1 to 400; refund the first payment
# with a balance, an amount from 1 up to that balance, the whole balance one
# time in twenty; after every refund, check that the reported balance
# matches the predicted one. `Corpus.Next.Scheme.RangeModel` ports the
# offset refund entry's model, which draws the amount uniformly.

Code.require_file("../../support/scheme.exs", __DIR__)

defmodule Corpus.Next.Scheme.Events do
  @moduledoc "What happened against the scheme."

  defmodule Paid do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, payment_id: external()]
  end

  defmodule Refunded do
    @moduledoc false
    # `balance` is the payment's balance after the refund, as the scheme reports it.
    defstruct [:payment_id, :amount, :balance]
  end
end

defmodule Corpus.Next.Scheme.Pay do
  @moduledoc "Pay an amount from 1 to 400."
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: integer(1..400)}
end

defmodule Corpus.Next.Scheme.Refund do
  @moduledoc """
  Refund part or all of a payment: the first payment, in the order they were
  made, that still has a balance, and an amount from 1 up to that balance.
  """
  use PropertyDamage.Next.Command

  alias Corpus.Next.Scheme.Projection

  defstruct [:payment_id, :amount]

  def generator(state, _opts) do
    %{
      payment_id: member_of([Projection.first_refundable(state)]),
      amount: from(:payment_id, fn id -> integer(1..state.payments[id].expected) end)
    }
  end
end

defmodule Corpus.Next.Scheme.Projection do
  @moduledoc """
  Tracks what each payment's balance should be next to what the scheme reports,
  and checks after every refund that the two agree.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}
  alias Corpus.Next.Scheme.Refund

  @impl true
  def init, do: %{payments: %{}, order: [], last_refund: nil}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}) do
    %{
      state
      | payments: Map.put(state.payments, id, %{expected: amount, reported: amount}),
        order: state.order ++ [id]
    }
  end

  def apply(state, %Refunded{payment_id: id, amount: amount, balance: balance}) do
    state
    |> update_in([:payments, id], &%{expected: &1.expected - amount, reported: balance})
    |> Map.put(:last_refund, id)
  end

  def apply(state, _event), do: state

  @doc "Whether some payment still has a balance to refund."
  def refundable?(state), do: first_refundable(state) != nil

  @doc "The first payment, in the order they were made, that still has a balance."
  def first_refundable(state), do: Enum.find(state.order, &(state.payments[&1].expected > 0))

  @check every: Refund
  def balance_matches_model(state, _command) do
    %{expected: expected, reported: reported} = state.payments[state.last_refund]

    reported == expected or
      PropertyDamage.fail!(
        "The scheme reports a balance of #{reported}, the model expects #{expected}",
        expected: expected,
        reported: reported
      )
  end
end

defmodule Corpus.Next.Scheme.Simulator do
  @moduledoc "Predicts the events of a command before any scheme exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}
  alias Corpus.Next.Scheme.{Pay, Refund}

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment_id: id, amount: amount}, state) do
    [%Refunded{payment_id: id, amount: amount, balance: state.payments[id].expected - amount}]
  end

  def simulate(_command, _state), do: []
end

defmodule Corpus.Next.Scheme.RefundModel do
  @moduledoc """
  Pays and refunds, with every response delivered. One refund amount in
  twenty takes the payment's whole balance; the rest are drawn from 1 up to
  the balance.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Pay, Projection, Refund}
  alias PropertyDamage.Next.{Command, Gen, StepSpec}

  def steps do
    [pay, refund] =
      StepSpec.normalize([
        {Pay, weight: 2},
        {Refund, weight: 3, when: &Projection.refundable?/1}
      ])

    [pay, StepSpec.update_command(refund, &favor_full_refund/2)]
  end

  # The amount depends on the drawn payment's balance and mixes two
  # generators by weight, which no PD description can say, so it is a
  # StreamData generator returned by a from/2 function.
  defp favor_full_refund(fields, state) do
    amount =
      Command.from(:payment_id, fn id ->
        balance = state.payments[id].expected
        Gen.frequency([{19, Gen.integer(1..balance)}, {1, Gen.constant(balance)}])
      end)

    Map.put(fields, :amount, amount)
  end

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Simulator
end

defmodule Corpus.Next.Scheme.Adapter do
  @moduledoc """
  Runs the scheme commands against a `Corpus.Scheme` started with the entry's
  `:bug` and `:fire_log`, taken from the run's config.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}
  alias Corpus.Next.Scheme.{Pay, Refund}
  alias Corpus.Scheme

  @impl true
  def setup(config, _runtime) do
    {:ok, scheme} = Scheme.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{scheme: scheme}}
  end

  @impl true
  def teardown(%{scheme: scheme}) do
    if Process.alive?(scheme), do: Scheme.stop(scheme)
    :ok
  end

  @impl true
  def execute(%Pay{amount: amount}, _assigns, %{scheme: scheme}) do
    {:ok, id} = Scheme.pay(scheme, amount)
    {:ok, [%Paid{payment_id: id, amount: amount}]}
  end

  def execute(%Refund{payment_id: id, amount: amount}, _assigns, %{scheme: scheme}) do
    case Scheme.refund(scheme, id, amount, lose_response: false) do
      {:ok, balance} -> {:ok, [%Refunded{payment_id: id, amount: amount, balance: balance}]}
      {:error, reason} -> {:error, reason}
    end
  end
end
