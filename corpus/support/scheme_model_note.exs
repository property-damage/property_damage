defmodule Corpus.Scheme.Noted.Events do
  @moduledoc "What happened against the scheme when refunds carry a note."

  defmodule Refunded do
    @moduledoc false
    # `note` is the note sent; `stored_note` is the note as the scheme kept it.
    defstruct [:payment_id, :amount, :balance, :note, :stored_note]
  end
end

defmodule Corpus.Scheme.Noted.Refund do
  @moduledoc """
  Refund part or all of a payment, with a free-text note of 0 to 60
  alphanumeric characters. The model chooses the payment and the amount.

  The generator draws the note's length itself, because the framework runs
  string generators at a fixed size that never reaches 40 characters.
  """
  use PropertyDamage.Command, observables: [Corpus.Scheme.Noted.Events.Refunded]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:payment_id, :amount, :note]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      payment_id: nil,
      amount: StreamData.integer(1..400),
      note:
        StreamData.bind(StreamData.integer(0..60), fn length ->
          StreamData.string(:alphanumeric, length: length)
        end)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Scheme.Noted.Projection do
  @moduledoc """
  Tracks what each payment's balance should be, and checks after every refund
  that the scheme stored the note it was sent.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Scheme.Events.Paid
  alias Corpus.Scheme.Noted.Events.Refunded
  alias Corpus.Scheme.Noted.Refund

  @impl true
  def init, do: %{payments: %{}, last: nil}

  @impl true
  def apply(state, %Paid{payment_id: id, amount: amount}) do
    put_in(state, [:payments, id], %{expected: amount})
  end

  def apply(state, %Refunded{payment_id: id, amount: amount, note: note, stored_note: stored}) do
    state
    |> update_in([:payments, id], &%{&1 | expected: &1.expected - amount})
    |> Map.put(:last, %{note: note, stored_note: stored})
  end

  def apply(state, _event), do: state

  @doc "Whether some payment still has a balance to refund."
  def refundable?(state), do: Enum.any?(state.payments, fn {_id, p} -> p.expected > 0 end)

  @doc "Overrides for a refund of the first payment (in key order) that has a balance."
  def refund_overrides(state) do
    {id, %{expected: balance}} =
      state.payments
      |> Enum.filter(fn {_id, p} -> p.expected > 0 end)
      |> Enum.min_by(&elem(&1, 0))

    %{payment_id: id, amount: StreamData.integer(1..balance)}
  end

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

defmodule Corpus.Scheme.Noted.Simulator do
  @moduledoc "Predicts the events of a command before any scheme exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Scheme.Events.Paid
  alias Corpus.Scheme.Noted.Events.Refunded
  alias Corpus.Scheme.Noted.Refund
  alias Corpus.Scheme.Pay

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

defmodule Corpus.Scheme.Noted.Model do
  @moduledoc "Pays and refunds with a note on every refund."
  use PropertyDamage.Model

  alias Corpus.Scheme.Noted.{Projection, Refund}
  alias Corpus.Scheme.Pay

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
  def simulator, do: Corpus.Scheme.Noted.Simulator
end

defmodule Corpus.Scheme.Noted.Adapter do
  @moduledoc "Runs the noted-refund commands against a `Corpus.Scheme` started with the entry's bug."
  use PropertyDamage.Adapter

  alias Corpus.Scheme
  alias Corpus.Scheme.Events.Paid
  alias Corpus.Scheme.Noted.Events.Refunded
  alias Corpus.Scheme.Noted.Refund
  alias Corpus.Scheme.Pay

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
    case Scheme.refund_noted(scheme, refund.payment_id, refund.amount, refund.note) do
      {:ok, balance, stored} ->
        {:ok,
         [
           %Refunded{
             payment_id: refund.payment_id,
             amount: refund.amount,
             balance: balance,
             note: refund.note,
             stored_note: stored
           }
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
