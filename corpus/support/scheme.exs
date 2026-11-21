defmodule Corpus.Scheme do
  @moduledoc """
  A small payment scheme: payments and refunds against them.

  Started with `bug: nil` it behaves correctly. Two bugs sit behind the switch:

    * `:lost_full_refund`: a refund that empties a payment whose amount is
      above 100 is accepted, but its credit is never applied.
    * `:double_credit`: when a refund's response is lost, the client retries
      it. A correct scheme sends the retry with the refund's idempotency key
      and applies the credit once. With this bug the retry has no key, so the
      credit is applied twice.

  Each time a buggy path runs, the scheme records it in the fire log.
  """

  use Agent

  alias PropertyDamage.Corpus.FireLog

  @doc "Starts a scheme. Options: `:bug` (default `nil`) and `:fire_log`."
  def start(opts) do
    log = Keyword.get(opts, :fire_log)
    instance = FireLog.started(log)

    Agent.start_link(fn ->
      %{
        bug: Keyword.get(opts, :bug),
        log: log,
        instance: instance,
        next_id: 1,
        payments: %{},
        applied_keys: MapSet.new()
      }
    end)
  end

  @doc "Stops the scheme."
  def stop(scheme), do: Agent.stop(scheme)

  @doc "Accepts a payment of `amount`; returns its id."
  def pay(scheme, amount) do
    Agent.get_and_update(scheme, fn state ->
      id = "pay_#{state.next_id}"
      payment = %{amount: amount, balance: amount}

      {{:ok, id},
       %{state | next_id: state.next_id + 1, payments: Map.put(state.payments, id, payment)}}
    end)
  end

  @doc """
  Refunds `amount` of payment `id`; returns the payment's balance afterwards.

  With `lose_response: true` the first response is lost and the client retries.
  """
  def refund(scheme, id, amount, opts \\ []) do
    lose_response? = Keyword.get(opts, :lose_response, false)
    Agent.get_and_update(scheme, &apply_refund(&1, id, amount, lose_response?))
  end

  defp apply_refund(state, id, amount, lose_response?) do
    case Map.fetch(state.payments, id) do
      :error ->
        {{:error, :unknown_payment}, state}

      {:ok, %{balance: balance}} when amount > balance ->
        {{:error, :exceeds_balance}, state}

      {:ok, payment} ->
        key = {id, state.next_id}
        state = %{state | next_id: state.next_id + 1}
        state = credit(state, id, payment, amount, key)
        state = if lose_response?, do: retry(state, id, amount, key), else: state
        {{:ok, state.payments[id].balance}, state}
    end
  end

  defp credit(%{bug: :lost_full_refund} = state, id, payment, amount, _key)
       when payment.amount > 100 and amount == payment.balance do
    FireLog.fired(state.log, state.instance)
    put_in(state, [:payments, id], payment)
  end

  defp credit(state, id, payment, amount, key) do
    state = %{state | applied_keys: MapSet.put(state.applied_keys, key)}
    put_in(state, [:payments, id], %{payment | balance: payment.balance - amount})
  end

  # The client retries a refund whose response was lost. The retry carries the
  # refund's key, so a correct scheme finds it applied already.
  defp retry(%{bug: :double_credit} = state, id, amount, _key) do
    FireLog.fired(state.log, state.instance)
    payment = state.payments[id]
    put_in(state, [:payments, id], %{payment | balance: payment.balance - amount})
  end

  defp retry(state, _id, _amount, key) do
    true = MapSet.member?(state.applied_keys, key)
    state
  end
end
