# A scheme model and adapter for two lanes of refunds. It drives the same
# system as `scheme_model.exs`, reuses that file's commands and events, and
# adds the refusal a lane gets when the other lane refunded first. The
# projection folds every event and checks a bound over its own state, not
# the balance each lane predicted, because each lane predicts without
# knowing what the other lane does.

Code.require_file("scheme_model.exs", __DIR__)

defmodule Corpus.Next.Scheme.RaceEvents do
  @moduledoc "Events only the racing refunds model uses."

  defmodule RefundRefused do
    @moduledoc false
    # The scheme refused a refund that its own lane's state allowed.
    defstruct [:payment_id, :amount]
  end
end

defmodule Corpus.Next.Scheme.RaceProjection do
  @moduledoc """
  Tracks what each payment was paid and how much the scheme refunded, and
  checks after every refund that the scheme never refunded more than was paid.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}
  alias Corpus.Next.Scheme.Refund

  @impl true
  def init, do: %{payments: %{}, order: []}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}) do
    %{
      state
      | payments: Map.put(state.payments, id, %{paid: amount, expected: amount, refunded: 0}),
        order: state.order ++ [id]
    }
  end

  def apply(state, %Refunded{payment_id: id, amount: amount}) do
    update_in(state, [:payments, id], fn payment ->
      %{payment | refunded: payment.refunded + amount, expected: payment.expected - amount}
    end)
  end

  def apply(state, _event), do: state

  @doc "Whether some payment still has a balance to refund."
  def refundable?(state), do: Enum.any?(state.order, &(state.payments[&1].expected > 0))

  @check every: Refund
  def never_refunds_more_than_paid(state, _command) do
    case Enum.find(state.order, &(state.payments[&1].refunded > state.payments[&1].paid)) do
      nil ->
        true

      id ->
        %{paid: paid, refunded: refunded} = state.payments[id]

        PropertyDamage.fail!(
          "Payment #{id} paid #{paid} and the scheme accepted refunds of #{refunded}",
          paid: paid,
          refunded: refunded
        )
    end
  end
end

defmodule Corpus.Next.Scheme.RaceSimulator do
  @moduledoc "Predicts each command in its own lane: a refund is accepted."
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

defmodule Corpus.Next.Scheme.RaceModel do
  @moduledoc """
  Pays and refunds the first payment that still has a balance, for plans with
  two lanes. A refund draws an amount from 1 up to that payment's balance as
  its own lane sees it.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Pay, Refund}
  alias Corpus.Next.Scheme.RaceProjection
  alias PropertyDamage.Next.StepSpec

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &RaceProjection.refundable?/1}
    ])
  end

  def command_sequence_projection, do: RaceProjection
  def check_projections, do: [RaceProjection]
  def simulator, do: Corpus.Next.Scheme.RaceSimulator
end

defmodule Corpus.Next.Scheme.RaceAdapter do
  @moduledoc """
  Runs the scheme commands against a `Corpus.Scheme` started with the entry's
  `:bug` and `:fire_log`, taken from the run's config. A refund yields between
  the scheme's check and its apply, so a step of the other lane can run there.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}
  alias Corpus.Next.Scheme.RaceEvents.RefundRefused
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
    case Scheme.begin_refund(scheme, id, amount) do
      {:ok, ticket} ->
        {:yield, fn -> finish(scheme, ticket, id, amount) end}

      {:error, :exceeds_balance} ->
        {:ok, [%RefundRefused{payment_id: id, amount: amount}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(scheme, ticket, id, amount) do
    case Scheme.finish_refund(scheme, ticket) do
      {:ok, balance} -> {:ok, [%Refunded{payment_id: id, amount: amount, balance: balance}]}
      {:error, :exceeds_balance} -> {:ok, [%RefundRefused{payment_id: id, amount: amount}]}
    end
  end
end
