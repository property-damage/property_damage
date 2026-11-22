# The running example for the new engine: a payment scheme with payments,
# refunds, refunds paid out in another currency, and reads. The commands,
# the model, the simulator, the projection and the adapter are what a user of
# the new engine writes; `PropertyDamage.Next.Test.Scheme.System` is the
# system under test.

defmodule PropertyDamage.Next.Test.Scheme.Events do
  @moduledoc false

  defmodule Paid do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    # The system mints the payment's id.
    defstruct [:amount, :currency, payment: external()]
  end

  defmodule Refunded do
    @moduledoc false
    # `balance` is the payment's balance after the refund, as reported.
    defstruct [:payment, :amount, :balance]
  end

  defmodule RefundRejected do
    @moduledoc false
    defstruct [:payment, :amount, :balance]
  end

  defmodule CurrencyRefunded do
    @moduledoc false
    # `debit` is the amount taken from the payment, in its own currency.
    defstruct [:payment, :currency, :amount, :debit, :balance]
  end

  defmodule TotalRead do
    @moduledoc false
    defstruct [:payment, :total]
  end

  defmodule Looked do
    @moduledoc false
    defstruct [:payment, :amount]
  end
end

defmodule PropertyDamage.Next.Test.Scheme.Pay do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount, :idempotency_key]

  def generator(_state, _opts),
    do: %{amount: integer(1..1_000), idempotency_key: mint_per_run(:uuid)}
end

defmodule PropertyDamage.Next.Test.Scheme.Refund do
  @moduledoc false
  # A refund stays below its payment's amount; how far below is the option
  # `:max_share`, which a model or a layer sets.
  use PropertyDamage.Next.Command

  defstruct [:payment, :amount, :idempotency_key]

  # The model's `when:`: a refund is offered only if this holds.
  def possible?(state), do: refundable(state) != []

  def generator(state, opts) do
    share = Keyword.get(opts, :max_share, 1.0)

    %{
      payment: member_of(refundable(state)),
      amount:
        from(:payment, fn p -> integer(1..upper_bound(state.payments[p].amount, share)) end),
      idempotency_key: mint_per_run(:uuid)
    }
  end

  @doc "Strictly below the payment's amount, and at least 1."
  def upper_bound(amount, share),
    do: amount |> Kernel.*(share) |> floor() |> min(amount - 1) |> max(1)

  @doc "Payments above 1, in the order they were made."
  def refundable(state), do: for(id <- state.order, state.payments[id].amount > 1, do: id)
end

defmodule PropertyDamage.Next.Test.Scheme.RefundedTotal do
  @moduledoc false
  # A read: the struct and a generator that picks the payment.
  use PropertyDamage.Next.Command

  defstruct [:payment]

  def generator(state, _opts), do: %{payment: member_of(state.order)}
end

defmodule PropertyDamage.Next.Test.Scheme.CurrencyRefund do
  @moduledoc false
  # A refund paid out in a currency of the merchant's choice: the amount
  # depends on two fields, so it uses the list form of `from/2`.
  use PropertyDamage.Next.Command

  alias PropertyDamage.Next.Test.Scheme.Refund

  defstruct [:payment, :currency, :amount]

  def possible?(state), do: Refund.possible?(state)

  def generator(state, _opts) do
    %{
      payment: member_of(Refund.refundable(state)),
      currency: member_of(state.settlement_currencies),
      amount:
        from([:payment, :currency], fn %{payment: p, currency: c} ->
          integer(1..upper_bound(state, p, c))
        end)
    }
  end

  # The payment's amount in the refund's currency, strictly below it, at least 1.
  defp upper_bound(state, p, c) do
    %{amount: amount, currency: paid_in} = state.payments[p]
    (amount * state.rates[{paid_in, c}]) |> floor() |> Kernel.-(1) |> max(1)
  end
end

defmodule PropertyDamage.Next.Test.Scheme.Lookup do
  @moduledoc false
  # A read that carries what the model predicts: the amount of the payment it
  # names. The adapter compares it with what the system answers, which shows
  # that a payment id threaded from an earlier step names the right payment.
  use PropertyDamage.Next.Command

  defstruct [:payment, :expected_amount]

  def generator(state, _opts) do
    %{
      payment: member_of(state.order),
      expected_amount:
        from(:payment, fn p ->
          amount = state.payments[p].amount
          integer(amount..amount)
        end)
    }
  end
end

defmodule PropertyDamage.Next.Test.Scheme.Payments do
  @moduledoc false
  # Tracks each payment's predicted balance next to the balance the system
  # reports, and checks that the two agree after every refund.
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Next.Test.Scheme.{CurrencyRefund, Refund, RefundedTotal, System}

  alias PropertyDamage.Next.Test.Scheme.Events.{
    CurrencyRefunded,
    Looked,
    Paid,
    Refunded,
    RefundRejected,
    TotalRead
  }

  @impl true
  def init do
    %{
      payments: %{},
      order: [],
      last: nil,
      last_total: nil,
      settlement_currencies: [:eur, :chf],
      rates: System.rates()
    }
  end

  @impl true
  def apply(state, %Paid{payment: id, amount: amount, currency: currency}) do
    payment = %{
      amount: amount,
      currency: currency,
      expected: amount,
      reported: amount,
      refunded: 0
    }

    %{state | payments: Map.put(state.payments, id, payment), order: state.order ++ [id]}
  end

  def apply(state, %Refunded{payment: id, amount: amount, balance: balance}),
    do: debit(state, id, amount, balance)

  def apply(state, %CurrencyRefunded{payment: id, debit: debit, balance: balance}),
    do: debit(state, id, debit, balance)

  def apply(state, %RefundRejected{payment: id, balance: balance}) do
    state
    |> update_in([:payments, id], &%{&1 | reported: balance})
    |> Map.put(:last, id)
  end

  def apply(state, %TotalRead{payment: id, total: total}),
    do: %{state | last_total: {id, total}}

  def apply(state, %Looked{}), do: state

  def apply(state, _event), do: state

  defp debit(state, id, amount, balance) do
    state
    |> update_in([:payments, id], fn p ->
      %{p | expected: p.expected - amount, reported: balance, refunded: p.refunded + amount}
    end)
    |> Map.put(:last, id)
  end

  @check every: Refund
  def balance_matches(state, _command), do: balance_agrees(state)

  @check every: CurrencyRefund
  def currency_balance_matches(state, _command), do: balance_agrees(state)

  @check every: RefundedTotal
  def total_matches(state, _command) do
    {id, total} = state.last_total
    refunded = state.payments[id].refunded

    total == refunded or
      PropertyDamage.fail!("The system reports #{total} refunded, the model expects #{refunded}")
  end

  @check every: 1
  def balances_never_negative(state, _command_or_event) do
    Enum.all?(state.payments, fn {_id, p} -> p.reported >= 0 end) or
      PropertyDamage.fail!("A reported balance is negative")
  end

  defp balance_agrees(state) do
    %{expected: expected, reported: reported} = state.payments[state.last]

    reported == expected or
      PropertyDamage.fail!(
        "The system reports a balance of #{reported}, the model expects #{expected}"
      )
  end
end

defmodule PropertyDamage.Next.Test.Scheme.Simulator do
  @moduledoc false
  # Predicts the events of a command from the predicted state alone.
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Next.Test.Scheme.{CurrencyRefund, Lookup, Pay, Refund, RefundedTotal}

  alias PropertyDamage.Next.Test.Scheme.Events.{
    CurrencyRefunded,
    Looked,
    Paid,
    Refunded,
    RefundRejected,
    TotalRead
  }

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount, currency: :eur}]

  def simulate(%Refund{payment: id, amount: amount}, state) do
    %{expected: balance} = state.payments[id]

    if amount > balance,
      do: [%RefundRejected{payment: id, amount: amount, balance: balance}],
      else: [%Refunded{payment: id, amount: amount, balance: balance - amount}]
  end

  def simulate(%CurrencyRefund{payment: id, currency: currency, amount: amount}, state) do
    %{expected: balance, currency: paid_in} = state.payments[id]
    rate = state.rates[{paid_in, currency}]
    debit = div(amount + rate - 1, rate)

    if debit > balance do
      [%RefundRejected{payment: id, amount: amount, balance: balance}]
    else
      [
        %CurrencyRefunded{
          payment: id,
          currency: currency,
          amount: amount,
          debit: debit,
          balance: balance - debit
        }
      ]
    end
  end

  def simulate(%RefundedTotal{payment: id}, state),
    do: [%TotalRead{payment: id, total: state.payments[id].refunded}]

  def simulate(%Lookup{payment: id}, state),
    do: [%Looked{payment: id, amount: state.payments[id].amount}]

  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Scheme.Model do
  @moduledoc false
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.{Pay, Refund, RefundedTotal}

  def steps do
    [
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Refund.possible?/1, command_opts: [max_share: 0.5]},
      {RefundedTotal, when: &Refund.possible?/1}
    ]
    |> StepSpec.normalize()
  end

  def simulator, do: PropertyDamage.Next.Test.Scheme.Simulator
  def command_sequence_projection, do: PropertyDamage.Next.Test.Scheme.Payments
  def check_projections, do: [PropertyDamage.Next.Test.Scheme.Payments]
end

defmodule PropertyDamage.Next.Test.Scheme.CurrencyModel do
  @moduledoc false
  # The base model plus currency refunds, added on the list.
  use PropertyDamage.Next.Model

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.{CurrencyRefund, Model}

  def steps do
    Model.steps() ++ StepSpec.normalize([{CurrencyRefund, when: &CurrencyRefund.possible?/1}])
  end

  def simulator, do: Model.simulator()
  def command_sequence_projection, do: Model.command_sequence_projection()
  def check_projections, do: Model.check_projections()
end

defmodule PropertyDamage.Next.Test.Scheme.Adapter do
  @moduledoc false
  # Runs the scheme commands against a fresh system per execution.
  #
  # Config keys: `:fault` (passed to the system; `:refund_error` makes every
  # refund answer an error and `:refund_raises` makes it raise, both in the
  # adapter) and `:recorder` (a pid that receives
  # `{:scheme_executed, command, assigns, result}` for every call).
  @behaviour PropertyDamage.Next.Adapter

  alias PropertyDamage.Next.Test.Scheme.{
    CurrencyRefund,
    Lookup,
    Pay,
    Refund,
    RefundedTotal,
    System
  }

  alias PropertyDamage.Next.Test.Scheme.Events.{
    CurrencyRefunded,
    Looked,
    Paid,
    Refunded,
    RefundRejected,
    TotalRead
  }

  @impl true
  def setup(config, _runtime) do
    fault = Map.get(config, :fault)
    {:ok, system} = System.start_link(fault: fault)
    {:ok, %{system: system, fault: fault, recorder: Map.get(config, :recorder)}}
  end

  @impl true
  def teardown(%{system: system}) do
    if Process.alive?(system), do: System.stop(system)
    :ok
  end

  @impl true
  def execute(command, assigns, context) do
    result = call(command, context)
    if context.recorder, do: send(context.recorder, {:scheme_executed, command, assigns, result})
    result
  end

  defp call(%Pay{amount: amount, idempotency_key: key}, %{system: system}) do
    {:ok, id} = System.pay(system, amount, key)
    {:ok, [%Paid{payment: id, amount: amount, currency: :eur}]}
  end

  defp call(%Refund{}, %{fault: :refund_error}), do: {:error, :refund_unavailable}
  defp call(%Refund{}, %{fault: :refund_raises}), do: raise("the refund endpoint crashed")

  defp call(%Refund{payment: id, amount: amount}, %{system: system}) do
    case System.refund(system, id, amount) do
      {:ok, balance} ->
        {:ok, [%Refunded{payment: id, amount: amount, balance: balance}]}

      {:rejected, balance} ->
        {:ok, [%RefundRejected{payment: id, amount: amount, balance: balance}]}

      {:error, reason} ->
        {:error, {reason, id}}
    end
  end

  defp call(%CurrencyRefund{payment: id, currency: currency, amount: amount}, %{system: system}) do
    case System.currency_refund(system, id, currency, amount) do
      {:ok, debit, balance} ->
        {:ok,
         [
           %CurrencyRefunded{
             payment: id,
             currency: currency,
             amount: amount,
             debit: debit,
             balance: balance
           }
         ]}

      {:rejected, _debit, balance} ->
        {:ok, [%RefundRejected{payment: id, amount: amount, balance: balance}]}

      {:error, reason} ->
        {:error, {reason, id}}
    end
  end

  defp call(%RefundedTotal{payment: id}, %{system: system}) do
    case System.refunded_total(system, id) do
      {:ok, total} -> {:ok, [%TotalRead{payment: id, total: total}]}
      {:error, reason} -> {:error, {reason, id}}
    end
  end

  defp call(%Lookup{payment: id}, %{system: system}) do
    case System.amount_of(system, id) do
      {:ok, amount} -> {:ok, [%Looked{payment: id, amount: amount}]}
      {:error, reason} -> {:error, {reason, id}}
    end
  end
end
