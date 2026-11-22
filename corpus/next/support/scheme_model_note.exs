# The long note model, written for the new engine: a port of the default
# corpus directory's noted-refund model. It pays with the commands of
# `scheme_model.exs` and refunds with a note on every refund; after every
# refund it checks that the scheme stored the note it was sent.

Code.require_file("scheme_model.exs", __DIR__)

defmodule Corpus.Next.Scheme.Noted.Events do
  @moduledoc "What happened against the scheme when refunds carry a note."

  defmodule Refunded do
    @moduledoc false
    # `note` is the note sent; `stored_note` is the note as the scheme kept it.
    defstruct [:payment_id, :amount, :balance, :note, :stored_note]
  end
end

defmodule Corpus.Next.Scheme.Noted.Refund do
  @moduledoc """
  Refund part or all of a payment, with a free-text note of 0 to 60
  alphanumeric characters: the first payment, in the order they were made,
  that still has a balance, and an amount from 1 up to that balance.

  The generator draws the note's length itself, because the engine draws
  StreamData generators at a fixed size that never reaches 40 characters.
  """
  use PropertyDamage.Next.Command

  alias Corpus.Next.Scheme.Noted.Projection

  defstruct [:payment_id, :amount, :note]

  def generator(state, _opts) do
    %{
      payment_id: member_of([Projection.first_refundable(state)]),
      amount: from(:payment_id, fn id -> integer(1..state.payments[id].expected) end),
      note: bind(integer(0..60), fn length -> string(:alphanumeric, length: length) end)
    }
  end
end

defmodule Corpus.Next.Scheme.Noted.Projection do
  @moduledoc """
  Tracks what each payment's balance should be, and checks after every refund
  that the scheme stored the note it was sent.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Next.Scheme.Events.Paid
  alias Corpus.Next.Scheme.Noted.Events.Refunded
  alias Corpus.Next.Scheme.Noted.Refund

  @impl true
  def init, do: %{payments: %{}, order: [], last: nil}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}) do
    %{
      state
      | payments: Map.put(state.payments, id, %{expected: amount}),
        order: state.order ++ [id]
    }
  end

  def apply(state, %Refunded{payment_id: id, amount: amount, note: note, stored_note: stored}) do
    state
    |> update_in([:payments, id], &%{&1 | expected: &1.expected - amount})
    |> Map.put(:last, %{note: note, stored_note: stored})
  end

  def apply(state, _event), do: state

  @doc "Whether some payment still has a balance to refund."
  def refundable?(state), do: first_refundable(state) != nil

  @doc "The first payment, in the order they were made, that still has a balance."
  def first_refundable(state), do: Enum.find(state.order, &(state.payments[&1].expected > 0))

  @check every: Refund
  def note_is_stored_as_sent(state, _command) do
    %{note: note, stored_note: stored} = state.last

    stored == note or
      PropertyDamage.fail!(
        "The scheme stored a note of #{String.length(stored)} characters, " <>
          "the model sent one of #{String.length(note)}",
        sent: note,
        stored: stored
      )
  end
end

defmodule Corpus.Next.Scheme.Noted.Simulator do
  @moduledoc "Predicts the events of a command before any scheme exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Next.Scheme.Events.Paid
  alias Corpus.Next.Scheme.Noted.Events.Refunded
  alias Corpus.Next.Scheme.Noted.Refund
  alias Corpus.Next.Scheme.Pay

  @impl true
  def simulate(%Pay{amount: amount}, _state), do: [%Paid{amount: amount}]

  def simulate(%Refund{payment_id: id, amount: amount, note: note}, state) do
    [
      %Refunded{
        payment_id: id,
        amount: amount,
        balance: state.payments[id].expected - amount,
        note: note,
        stored_note: note
      }
    ]
  end

  def simulate(_command, _state), do: []
end

defmodule Corpus.Next.Scheme.Noted.Model do
  @moduledoc "Pays and refunds with a note on every refund."
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.Noted.{Projection, Refund}
  alias Corpus.Next.Scheme.Pay
  alias PropertyDamage.Next.StepSpec

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Projection.refundable?/1}
    ])
  end

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Noted.Simulator
end

defmodule Corpus.Next.Scheme.Noted.Adapter do
  @moduledoc """
  Runs the noted-refund commands against a `Corpus.Scheme` started with the
  entry's `:bug` and `:fire_log`, taken from the run's config.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Scheme.Events.Paid
  alias Corpus.Next.Scheme.Noted.Events.Refunded
  alias Corpus.Next.Scheme.Noted.Refund
  alias Corpus.Next.Scheme.Pay
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

  def execute(%Refund{payment_id: id, amount: amount, note: note}, _assigns, %{scheme: scheme}) do
    case Scheme.refund_noted(scheme, id, amount, note) do
      {:ok, balance, stored} ->
        {:ok,
         [
           %Refunded{
             payment_id: id,
             amount: amount,
             balance: balance,
             note: note,
             stored_note: stored
           }
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
