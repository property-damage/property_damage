defmodule Corpus.Scheme.Events do
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

defmodule Corpus.Scheme.Pay do
  @moduledoc "Pay an amount from 1 to 400."
  use PropertyDamage.Command, observables: [Corpus.Scheme.Events.Paid]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..400)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Scheme.Refund do
  @moduledoc """
  Refund part or all of a payment.

  The model chooses the payment and the amount range (see
  `Corpus.Scheme.Projection.refund_overrides/1`). `lose_response` is set on
  one refund in ten unless the model overrides it.
  """
  use PropertyDamage.Command, observables: [Corpus.Scheme.Events.Refunded]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:payment_id, :amount, lose_response: false]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      payment_id: nil,
      amount: StreamData.integer(1..400),
      lose_response:
        StreamData.frequency([{9, StreamData.constant(false)}, {1, StreamData.constant(true)}])
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Scheme.Projection do
  @moduledoc """
  Tracks what each payment's balance should be next to what the scheme reports,
  and checks after every refund that the two agree.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Scheme.Events.{Paid, Refunded}
  alias Corpus.Scheme.Refund

  @impl true
  def init, do: %{payments: %{}, last_refund: nil}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}) do
    put_in(state, [:payments, id], %{expected: amount, reported: amount})
  end

  def apply(state, %Refunded{payment_id: id, amount: amount, balance: balance}) do
    state
    |> update_in([:payments, id], &%{expected: &1.expected - amount, reported: balance})
    |> Map.put(:last_refund, id)
  end

  def apply(state, _event), do: state

  @doc "Whether some payment still has a balance to refund."
  def refundable?(state), do: Enum.any?(state.payments, fn {_id, p} -> p.expected > 0 end)

  @doc """
  Overrides for a refund of the first payment (in key order) that has a balance.

  The amount runs from 1 up to that balance, so a refund may equal the payment;
  one draw in twenty takes the whole balance.
  """
  def refund_overrides(state) do
    {id, %{expected: balance}} =
      state.payments
      |> Enum.filter(fn {_id, p} -> p.expected > 0 end)
      |> Enum.min_by(&elem(&1, 0))

    %{
      payment_id: id,
      amount:
        StreamData.frequency([
          {19, StreamData.integer(1..balance)},
          {1, StreamData.constant(balance)}
        ])
    }
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

defmodule Corpus.Scheme.Simulator do
  @moduledoc "Predicts the events of a command before any scheme exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Scheme.Events.{Paid, Refunded}
  alias Corpus.Scheme.{Pay, Refund}

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment_id: id, amount: amount}, state) do
    [%Refunded{payment_id: id, amount: amount, balance: state.payments[id].expected - amount}]
  end

  def simulate(_command, _state), do: []
end

defmodule Corpus.Scheme.RefundModel do
  @moduledoc "Pays and refunds, with every response delivered."
  use PropertyDamage.Model

  alias Corpus.Scheme.{Pay, Projection, Refund}

  @impl true
  def commands do
    [
      {Pay, weight: 2},
      {Refund,
       weight: 3,
       when: &Projection.refundable?/1,
       overrides: fn state ->
         Map.put(Projection.refund_overrides(state), :lose_response, false)
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: Projection

  @impl true
  def check_projections, do: [Projection]

  @impl true
  def simulator, do: Corpus.Scheme.Simulator
end

defmodule Corpus.Scheme.RetryModel do
  @moduledoc "Pays and refunds; some refunds lose their response and are retried."
  use PropertyDamage.Model

  alias Corpus.Scheme.{Pay, Projection, Refund}

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
  def simulator, do: Corpus.Scheme.Simulator
end

defmodule Corpus.Scheme.Adapter do
  @moduledoc "Runs the scheme commands against a `Corpus.Scheme` started with the entry's bug."
  use PropertyDamage.Adapter

  alias Corpus.Scheme
  alias Corpus.Scheme.Events.{Paid, Refunded}
  alias Corpus.Scheme.{Pay, Refund}

  @impl true
  def setup(config) do
    {:ok, scheme} = Scheme.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{scheme: scheme}}
  end

  @impl true
  def teardown(%{scheme: scheme}) do
    if Process.alive?(scheme), do: Scheme.stop(scheme)
    :ok
  end

  @impl true
  def execute(%Pay{amount: amount}, %{scheme: scheme}, _runtime) do
    {:ok, id} = Scheme.pay(scheme, amount)
    {:ok, [%Paid{payment_id: id, amount: amount}]}
  end

  def execute(%Refund{} = refund, %{scheme: scheme}, _runtime) do
    opts = [lose_response: refund.lose_response]

    case Scheme.refund(scheme, refund.payment_id, refund.amount, opts) do
      {:ok, balance} ->
        {:ok, [%Refunded{payment_id: refund.payment_id, amount: refund.amount, balance: balance}]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
