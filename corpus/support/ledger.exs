defmodule Corpus.Ledger do
  @moduledoc """
  A small account ledger.

  Started with `bug: nil` it keeps the balance its deposits and withdrawals
  imply. With `bug: :double_debit_from_12` a withdrawal of 12 or more debits
  twice its amount, and the ledger records that in the fire log.
  """

  use Agent

  alias PropertyDamage.Corpus.FireLog

  @threshold 12

  @doc "Starts a ledger with a zero balance. Options: `:bug` (default `nil`) and `:fire_log`."
  def start(opts) do
    log = Keyword.get(opts, :fire_log)
    instance = FireLog.started(log)

    Agent.start_link(fn ->
      %{bug: Keyword.get(opts, :bug), log: log, instance: instance, balance: 0}
    end)
  end

  @doc "Stops the ledger."
  def stop(ledger), do: Agent.stop(ledger)

  @doc "Adds `amount`; returns the new balance."
  def deposit(ledger, amount) do
    Agent.get_and_update(ledger, fn state ->
      balance = state.balance + amount
      {balance, %{state | balance: balance}}
    end)
  end

  @doc "Takes `amount` out; returns the new balance."
  def withdraw(ledger, amount) do
    Agent.get_and_update(ledger, fn state ->
      balance = state.balance - debit(state, amount)
      {balance, %{state | balance: balance}}
    end)
  end

  defp debit(%{bug: :double_debit_from_12, log: log, instance: instance}, amount)
       when amount >= @threshold do
    FireLog.fired(log, instance)
    2 * amount
  end

  defp debit(_state, amount), do: amount
end
