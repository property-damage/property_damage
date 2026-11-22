defmodule PropertyDamage.Next do
  @moduledoc """
  The new engine's entry points.

  The test case of the new engine is a journal: one entry per draw, keyed
  by where generation made it. `plan/3` builds a plan from a seed, or
  rebuilds it from a journal, without executing anything.
  """

  alias PropertyDamage.Next.Engine.Native
  alias PropertyDamage.Next.{Generation, Journal, Model, ModelChangedError, Plan}

  @plan_opts [max_steps: 20, engine: Native]

  @doc """
  Builds the plan of `model` from a seed, or rebuilds it from a journal.

  From a seed, every draw is fresh and the plan's journal records each one.
  From a journal, generation runs again against its entries: a stored value
  that still fits is kept, and a stored pick that is no longer offered
  withdraws its slot. A journal recorded on a different spec list raises
  `PropertyDamage.Next.ModelChangedError`.

  Options:

    * `:max_steps` - the number of slots (default 20)
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)
  """
  @spec plan(module(), integer() | Journal.t(), keyword()) :: Plan.t()
  def plan(model, seed_or_journal, opts \\ []) when is_atom(model) do
    opts = Keyword.validate!(opts, @plan_opts)
    max_steps!(opts[:max_steps])
    specs = Model.specs!(model)
    fingerprint = Journal.fingerprint(specs)
    Generation.build(model, specs, journal!(seed_or_journal, fingerprint, model), opts)
  end

  defp journal!(seed, fingerprint, _model) when is_integer(seed),
    do: %Journal{seed: seed, entries: %{}, fingerprint: fingerprint}

  defp journal!(%Journal{fingerprint: fingerprint} = journal, fingerprint, _model), do: journal

  defp journal!(%Journal{fingerprint: recorded}, fingerprint, model),
    do: raise(ModelChangedError, model: model, expected: recorded, actual: fingerprint)

  defp journal!(other, _fingerprint, _model) do
    raise ArgumentError,
          "a plan is built from an integer seed or a journal, got: #{inspect(other)}"
  end

  defp max_steps!(n) when is_integer(n) and n >= 0, do: n

  defp max_steps!(other),
    do: raise(ArgumentError, "max_steps is a non-negative integer, got: #{inspect(other)}")
end
