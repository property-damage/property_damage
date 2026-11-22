defmodule PropertyDamage.Next.Test.Scheme.System do
  @moduledoc false
  # A small in-memory payment system for the running example: payments,
  # refunds against them, refunds paid out in another currency, and reads.
  #
  # Started with `fault: nil` it behaves correctly. `fault: :skip_credit`
  # accepts a refund but never lowers the payment's balance, so a model that
  # predicts balances sees the reported balance drift from its prediction.
  #
  # The system mints each payment's id itself, so a test can only learn the
  # id from the system's answer.

  use Agent

  # Units of the payout currency per unit of the payment's currency.
  @rates %{{:eur, :eur} => 1, {:eur, :chf} => 2}

  def rates, do: @rates

  def start_link(opts) do
    Agent.start_link(fn ->
      %{fault: Keyword.get(opts, :fault), next_id: 1, payments: %{}, keys: []}
    end)
  end

  def stop(system), do: Agent.stop(system)

  @doc "Accepts a payment; returns the id the system minted for it."
  def pay(system, amount, idempotency_key) do
    Agent.get_and_update(system, fn state ->
      id = "pay_#{state.next_id}"
      payment = %{amount: amount, currency: :eur, balance: amount, refunded: 0}

      {{:ok, id},
       %{
         state
         | next_id: state.next_id + 1,
           payments: Map.put(state.payments, id, payment),
           keys: [idempotency_key | state.keys]
       }}
    end)
  end

  @doc """
  Refunds `amount` of payment `id`.

  Returns `{:ok, balance}` when the refund is applied and
  `{:rejected, balance}` when it exceeds the balance.
  """
  def refund(system, id, amount) do
    Agent.get_and_update(system, &debit(&1, id, amount, amount))
  end

  @doc """
  Refunds `amount` units of `currency` against payment `id`.

  The payment is debited the amount converted back to its own currency,
  rounded up. Returns `{:ok, debit, balance}` or `{:rejected, debit, balance}`.
  """
  def currency_refund(system, id, currency, amount) do
    Agent.get_and_update(system, fn state ->
      case Map.fetch(state.payments, id) do
        :error ->
          {{:error, :unknown_payment}, state}

        {:ok, payment} ->
          debit = ceil_div(amount, Map.fetch!(@rates, {payment.currency, currency}))

          case debit(state, id, debit, debit) do
            {{:ok, balance}, state} -> {{:ok, debit, balance}, state}
            {{:rejected, balance}, state} -> {{:rejected, debit, balance}, state}
          end
      end
    end)
  end

  @doc "The total refunded against payment `id`."
  def refunded_total(system, id) do
    Agent.get(system, fn state ->
      case Map.fetch(state.payments, id) do
        {:ok, payment} -> {:ok, payment.refunded}
        :error -> {:error, :unknown_payment}
      end
    end)
  end

  @doc "The amount payment `id` was made for."
  def amount_of(system, id) do
    Agent.get(system, fn state ->
      case Map.fetch(state.payments, id) do
        {:ok, payment} -> {:ok, payment.amount}
        :error -> {:error, :unknown_payment}
      end
    end)
  end

  defp debit(state, id, debit, refunded) do
    case Map.fetch(state.payments, id) do
      :error ->
        {{:error, :unknown_payment}, state}

      {:ok, %{balance: balance}} when debit > balance ->
        {{:rejected, balance}, state}

      {:ok, payment} ->
        payment = apply_debit(state.fault, payment, debit, refunded)
        {{:ok, payment.balance}, put_in(state, [:payments, id], payment)}
    end
  end

  defp apply_debit(:skip_credit, payment, _debit, refunded),
    do: %{payment | refunded: payment.refunded + refunded}

  defp apply_debit(_fault, payment, debit, refunded),
    do: %{payment | balance: payment.balance - debit, refunded: payment.refunded + refunded}

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
