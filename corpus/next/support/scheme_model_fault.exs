# The double credit model, written for the new engine. It reuses the
# commands, projection and simulator of `scheme_model.exs` and adds one
# thing: a layer sets the assign `lose_response` beside the refund command.
# The assign is a fault, a fact about the network and not about the refund,
# so the model, its simulator and its projections never read it. Only the
# adapter's port acts on it, and acknowledges that it did.

Code.require_file("scheme_model.exs", __DIR__)

defmodule Corpus.Next.Scheme.Faults do
  @moduledoc "Layers that add faults to the scheme's steps."

  alias Corpus.Next.Scheme.Refund
  alias PropertyDamage.Next.{Gen, StepSpec}

  @doc "Adds the assign `lose_response` to every refund step."
  def lose_response(%StepSpec{command: Refund} = spec),
    do: StepSpec.assign(spec, :lose_response, Gen.boolean())

  def lose_response(spec), do: spec
end

defmodule Corpus.Next.Scheme.FaultModel do
  @moduledoc """
  Pays and refunds as `Corpus.Next.Scheme.RefundModel` does, with a layer
  that may lose the response of a refund.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Faults, Projection, RefundModel}
  alias PropertyDamage.Next.StepSpec

  def steps, do: RefundModel.steps() |> StepSpec.transform(&Faults.lose_response/1)

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Simulator
end

defmodule Corpus.Next.Scheme.FaultAdapter do
  @moduledoc """
  Runs the scheme commands against a `Corpus.Scheme` started with the entry's
  `:bug` and `:fire_log`, taken from the run's config. A refund whose
  `lose_response` assign is true loses its response in the scheme, and the
  port acknowledges the assign.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Scheme.Events.{Paid, Refunded}
  alias Corpus.Next.Scheme.{Pay, Refund}
  alias Corpus.Scheme
  alias PropertyDamage.Next.Runtime

  @impl true
  def setup(config, runtime) do
    {:ok, scheme} = Scheme.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{scheme: scheme, pd: runtime}}
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

  def execute(%Refund{} = refund, %{lose_response: true}, %{pd: pd} = context) do
    :ok = Runtime.ack(pd, :lose_response)
    refund(refund, context, true)
  end

  def execute(%Refund{} = refund, _assigns, context), do: refund(refund, context, false)

  defp refund(%Refund{payment_id: id, amount: amount}, %{scheme: scheme}, lose_response?) do
    case Scheme.refund(scheme, id, amount, lose_response: lose_response?) do
      {:ok, balance} -> {:ok, [%Refunded{payment_id: id, amount: amount, balance: balance}]}
      {:error, reason} -> {:error, reason}
    end
  end
end
