# The nested price model, written for the new engine. It drives the same
# system as the entry in the default corpus directory, `Corpus.Pricing`, and
# ports that entry's model: pay 1 to 60 base units; refund the first payment
# with a balance, at a price (an amount and a currency) whose converted value
# fits in that balance; after every refund, check that the reported balance
# matches the predicted one.

Code.require_file("../../support/pricing.exs", __DIR__)

defmodule Corpus.Next.Pricing.Events do
  @moduledoc "What happened against the pricing scheme."

  defmodule Paid do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, payment_id: external()]
  end

  defmodule Refunded do
    @moduledoc false
    # `balance` is the payment's balance after the refund, as the scheme reports it.
    defstruct [:payment_id, :price, :balance]
  end
end

defmodule Corpus.Next.Pricing.Pay do
  @moduledoc "Pay an amount from 1 to 60 base units."
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: integer(1..60)}
end

defmodule Corpus.Next.Pricing.Refund do
  @moduledoc """
  Refund part or all of a payment with a nested `price`, a map of an `amount`
  and a `currency` (`:base` or `:alt`): the first payment, in the order they
  were made, that still has a balance, at a price whose converted value fits
  in that balance.
  """
  use PropertyDamage.Next.Command

  alias Corpus.Next.Pricing.Projection

  defstruct [:payment_id, :price]

  # The price depends on the drawn payment's balance and is a nested value
  # of two fields chosen between two shapes, which no PD description can
  # say, so it is a StreamData generator returned by a from/2 function. The
  # keyword form of fixed_map draws the amount before the currency.
  def generator(state, _opts) do
    %{
      payment_id: member_of([Projection.first_refundable(state)]),
      price: from(:payment_id, fn id -> price_within(state.payments[id].expected) end)
    }
  end

  defp price_within(balance) do
    one_of([
      fixed_map(amount: integer(1..balance), currency: constant(:base)),
      fixed_map(amount: integer(1..div(2 * balance + 1, 3)), currency: constant(:alt))
    ])
  end
end

defmodule Corpus.Next.Pricing.Projection do
  @moduledoc """
  Tracks what each payment's balance should be next to what the scheme reports,
  and checks after every refund that the two agree.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Pricing.Events.{Paid, Refunded}
  alias Corpus.Next.Pricing.Refund
  alias Corpus.Pricing

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

  def apply(state, %Refunded{payment_id: id, price: price, balance: balance}) do
    %{amount: amount, currency: currency} = price

    state
    |> update_in(
      [:payments, id],
      &%{expected: &1.expected - Pricing.convert(amount, currency), reported: balance}
    )
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

defmodule Corpus.Next.Pricing.Simulator do
  @moduledoc "Predicts the events of a command before any scheme exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Next.Pricing.Events.{Paid, Refunded}
  alias Corpus.Next.Pricing.{Pay, Refund}
  alias Corpus.Pricing

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment_id: id, price: price}, state) do
    balance = state.payments[id].expected - Pricing.convert(price.amount, price.currency)
    [%Refunded{payment_id: id, price: price, balance: balance}]
  end

  def simulate(_command, _state), do: []
end

defmodule Corpus.Next.Pricing.Model do
  @moduledoc "Pays and refunds with a nested price on every refund."
  use PropertyDamage.Next.Model

  alias Corpus.Next.Pricing.{Pay, Projection, Refund}
  alias PropertyDamage.Next.StepSpec

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Projection.refundable?/1}
    ])
  end

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Pricing.Simulator
end

defmodule Corpus.Next.Pricing.Adapter do
  @moduledoc """
  Runs the pricing commands against a `Corpus.Pricing` started with the entry's
  `:bug` and `:fire_log`, taken from the run's config.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Pricing.Events.{Paid, Refunded}
  alias Corpus.Next.Pricing.{Pay, Refund}
  alias Corpus.Pricing

  @impl true
  def setup(config, _runtime) do
    {:ok, scheme} = Pricing.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{scheme: scheme}}
  end

  @impl true
  def teardown(%{scheme: scheme}) do
    if Process.alive?(scheme), do: Pricing.stop(scheme)
    :ok
  end

  @impl true
  def execute(%Pay{amount: amount}, _assigns, %{scheme: scheme}) do
    {:ok, id} = Pricing.pay(scheme, amount)
    {:ok, [%Paid{payment_id: id, amount: amount}]}
  end

  def execute(%Refund{payment_id: id, price: price}, _assigns, %{scheme: scheme}) do
    case Pricing.refund(scheme, id, price) do
      {:ok, balance} -> {:ok, [%Refunded{payment_id: id, price: price, balance: balance}]}
      {:error, reason} -> {:error, reason}
    end
  end
end
