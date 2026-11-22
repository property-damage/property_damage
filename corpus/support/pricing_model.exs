defmodule Corpus.Pricing.Events do
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

defmodule Corpus.Pricing.Pay do
  @moduledoc "Pay an amount from 1 to 60 base units."
  use PropertyDamage.Command, observables: [Corpus.Pricing.Events.Paid]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..60)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Pricing.Refund do
  @moduledoc """
  Refund part or all of a payment with a nested `price`, a map of an `amount`
  and a `currency` (`:base` or `:alt`). The model chooses the payment and bounds
  the price's amount by that payment's balance.
  """
  use PropertyDamage.Command, observables: [Corpus.Pricing.Events.Refunded]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:payment_id, :price]

  @impl true
  def generator(overrides \\ %{}) do
    %{payment_id: nil, price: price(60)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  @doc "A price whose amount is at most `max_amount`, in either currency."
  def price(max_amount) do
    StreamData.fixed_map(%{
      amount: StreamData.integer(1..max_amount),
      currency: StreamData.member_of([:base, :alt])
    })
  end
end

defmodule Corpus.Pricing.Projection do
  @moduledoc """
  Tracks what each payment's balance should be next to what the scheme reports,
  and checks after every refund that the two agree.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Pricing
  alias Corpus.Pricing.Events.{Paid, Refunded}
  alias Corpus.Pricing.Refund

  @impl true
  def init, do: %{payments: %{}, last_refund: nil}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}) do
    put_in(state, [:payments, id], %{expected: amount, reported: amount})
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
  def refundable?(state), do: Enum.any?(state.payments, fn {_id, p} -> p.expected > 0 end)

  @doc """
  Overrides for a refund of the first payment (in key order) that has a balance.

  The price's amount is bounded by that balance: the largest amount whose
  converted value still fits in it, in the alternate currency, or the balance
  itself, in the base currency.
  """
  def refund_overrides(state) do
    {id, %{expected: balance}} =
      state.payments
      |> Enum.filter(fn {_id, p} -> p.expected > 0 end)
      |> Enum.min_by(&elem(&1, 0))

    %{payment_id: id, price: price_within(balance)}
  end

  defp price_within(balance) do
    StreamData.one_of([
      StreamData.fixed_map(%{
        amount: StreamData.integer(1..balance),
        currency: StreamData.constant(:base)
      }),
      StreamData.fixed_map(%{
        amount: StreamData.integer(1..div(2 * balance + 1, 3)),
        currency: StreamData.constant(:alt)
      })
    ])
  end

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

defmodule Corpus.Pricing.Simulator do
  @moduledoc "Predicts the events of a command before any scheme exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Pricing
  alias Corpus.Pricing.Events.{Paid, Refunded}
  alias Corpus.Pricing.{Pay, Refund}

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment_id: id, price: price}, state) do
    balance = state.payments[id].expected - Pricing.convert(price.amount, price.currency)
    [%Refunded{payment_id: id, price: price, balance: balance}]
  end

  def simulate(_command, _state), do: []
end

defmodule Corpus.Pricing.Model do
  @moduledoc "Pays and refunds with a nested price on every refund."
  use PropertyDamage.Model

  alias Corpus.Pricing.{Pay, Projection, Refund}

  @impl true
  def commands do
    [
      {Pay, weight: 2},
      {Refund,
       weight: 3, when: &Projection.refundable?/1, overrides: &Projection.refund_overrides/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: Projection

  @impl true
  def check_projections, do: [Projection]

  @impl true
  def simulator, do: Corpus.Pricing.Simulator
end

defmodule Corpus.Pricing.Adapter do
  @moduledoc "Runs the pricing commands against a `Corpus.Pricing` started with the entry's bug."
  use PropertyDamage.Adapter

  alias Corpus.Pricing
  alias Corpus.Pricing.Events.{Paid, Refunded}
  alias Corpus.Pricing.{Pay, Refund}

  @impl true
  def setup(config) do
    {:ok, scheme} = Pricing.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{scheme: scheme}}
  end

  @impl true
  def teardown(%{scheme: scheme}) do
    if Process.alive?(scheme), do: Pricing.stop(scheme)
    :ok
  end

  @impl true
  def execute(%Pay{amount: amount}, %{scheme: scheme}, _runtime) do
    {:ok, id} = Pricing.pay(scheme, amount)
    {:ok, [%Paid{payment_id: id, amount: amount}]}
  end

  def execute(%Refund{} = refund, %{scheme: scheme}, _runtime) do
    case Pricing.refund(scheme, refund.payment_id, refund.price) do
      {:ok, balance} ->
        {:ok, [%Refunded{payment_id: refund.payment_id, price: refund.price, balance: balance}]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
