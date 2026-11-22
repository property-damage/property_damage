defmodule Corpus.Pricing do
  @moduledoc """
  A payment scheme that refunds in two currencies.

  A payment is in the base currency. A refund carries a price, an amount in
  `:base` or in `:alt`. One `:alt` unit converts to one and a half base units,
  rounded down. Started with `bug: nil` it behaves correctly. This bug sits
  behind the switch:

    * `:nested_price`: the conversion rounds up instead of down. An odd `:alt`
      amount converts one unit too high. If that exceeds the payment's balance
      the refund is rejected as `:exceeds_balance`; otherwise it credits one
      unit too many.

  Each time the buggy conversion differs from the correct one, the scheme
  records it in the fire log.
  """

  use Agent

  alias PropertyDamage.Corpus.FireLog

  @doc "Starts a scheme. Options: `:bug` (default `nil`) and `:fire_log`."
  def start(opts) do
    log = Keyword.get(opts, :fire_log)
    instance = FireLog.started(log)

    Agent.start_link(fn ->
      %{bug: Keyword.get(opts, :bug), log: log, instance: instance, next_id: 1, payments: %{}}
    end)
  end

  @doc "Stops the scheme."
  def stop(scheme), do: Agent.stop(scheme)

  @doc "Accepts a payment of `amount` base units; returns its id."
  def pay(scheme, amount) do
    Agent.get_and_update(scheme, fn state ->
      id = "pay_#{state.next_id}"
      payments = Map.put(state.payments, id, amount)
      {{:ok, id}, %{state | next_id: state.next_id + 1, payments: payments}}
    end)
  end

  @doc "The base units that `amount` of `currency` is worth, rounded down."
  def convert(amount, :base), do: amount
  def convert(amount, :alt), do: div(amount * 3, 2)

  @doc """
  Refunds `price` (`%{amount: n, currency: c}`) of payment `id`; returns the
  payment's balance afterwards.
  """
  def refund(scheme, id, %{amount: amount, currency: currency}) do
    Agent.get_and_update(scheme, fn state ->
      case Map.fetch(state.payments, id) do
        :error -> {{:error, :unknown_payment}, state}
        {:ok, balance} -> apply_refund(state, id, balance, converted(state, amount, currency))
      end
    end)
  end

  defp apply_refund(state, _id, balance, converted) when converted > balance,
    do: {{:error, :exceeds_balance}, state}

  defp apply_refund(state, id, balance, converted) do
    left = balance - converted
    {{:ok, left}, put_in(state, [:payments, id], left)}
  end

  defp converted(%{bug: :nested_price} = state, amount, :alt) when rem(amount, 2) == 1 do
    FireLog.fired(state.log, state.instance)
    div(amount * 3 + 1, 2)
  end

  defp converted(_state, amount, currency), do: convert(amount, currency)
end
