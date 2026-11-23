# Four small models and adapters, each committing one mistake that PD must
# catch. They reuse the scheme commands, projection and simulator of
# `scheme_model.exs`, and the fault layer and adapter of
# `scheme_model_fault.exs`; the corrected pair of each entry is one of the
# models and adapters defined there.

Code.require_file("scheme_model_fault.exs", __DIR__)

defmodule Corpus.Next.Guardrail.Layers do
  @moduledoc "A layer with a misspelled module name."

  alias PropertyDamage.Next.{Gen, StepSpec}

  @doc "Adds `lose_response` to the steps of `Corpus.Next.Scheme.Refnd`, a module that does not exist."
  def lose_response_misspelled(%StepSpec{command: Corpus.Next.Scheme.Refnd} = spec),
    do: StepSpec.assign(spec, :lose_response, Gen.boolean())

  def lose_response_misspelled(spec), do: spec
end

defmodule Corpus.Next.Guardrail.MisspelledLayerModel do
  @moduledoc """
  The fault model with a layer that matches a misspelled module, so it
  changes no spec.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Guardrail.Layers
  alias Corpus.Next.Scheme.{Projection, RefundModel}
  alias PropertyDamage.Next.StepSpec

  def steps, do: RefundModel.steps() |> StepSpec.transform(&Layers.lose_response_misspelled/1)

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Simulator
end

defmodule Corpus.Next.Guardrail.NoPayModel do
  @moduledoc """
  The refund model with its pay command dropped, so the refund, which needs a
  payment, is never eligible.
  """
  use PropertyDamage.Next.Model

  alias Corpus.Next.Scheme.{Pay, Projection, RefundModel}

  def steps, do: Enum.reject(RefundModel.steps(), &(&1.command == Pay))

  def command_sequence_projection, do: Projection
  def check_projections, do: [Projection]
  def simulator, do: Corpus.Next.Scheme.Simulator
end

defmodule Corpus.Next.Guardrail.MisspelledAssignAdapter do
  @moduledoc """
  The fault adapter with a clause that matches `lose_respnse`, a key no layer
  sets. The clause never runs, so nothing acknowledges `lose_response`.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Scheme.FaultAdapter
  alias Corpus.Next.Scheme.Refund
  alias PropertyDamage.Next.Runtime

  @impl true
  defdelegate setup(config, runtime), to: FaultAdapter

  @impl true
  defdelegate teardown(context), to: FaultAdapter

  @impl true
  def execute(%Refund{} = refund, %{lose_respnse: true}, %{pd: pd} = context) do
    :ok = Runtime.ack(pd, :lose_respnse)
    FaultAdapter.execute(refund, %{lose_response: true}, context)
  end

  def execute(command, _assigns, context), do: FaultAdapter.execute(command, %{}, context)
end

defmodule Corpus.Next.Guardrail.AckEveryRefundAdapter do
  @moduledoc """
  The fault adapter acknowledging `lose_response` at every refund, whether or
  not a spec set it.
  """
  @behaviour PropertyDamage.Next.Adapter

  alias Corpus.Next.Scheme.FaultAdapter
  alias Corpus.Next.Scheme.Refund
  alias PropertyDamage.Next.Runtime

  @impl true
  defdelegate setup(config, runtime), to: FaultAdapter

  @impl true
  defdelegate teardown(context), to: FaultAdapter

  @impl true
  def execute(%Refund{} = refund, assigns, %{pd: pd} = context) do
    :ok = Runtime.ack(pd, :lose_response)
    FaultAdapter.execute(refund, assigns, context)
  end

  def execute(command, assigns, context), do: FaultAdapter.execute(command, assigns, context)
end
