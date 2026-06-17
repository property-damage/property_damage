defmodule PropertyDamage.Progress do
  @moduledoc """
  The progress-projection envelope (DR-022).

  A `%PropertyDamage.Progress{}` is a *derived projection* of an operation's
  authoritative state at a checkpoint, fanned out to consumers (the `verbose:`
  printer, a user `on_progress:` callback, telemetry). It carries cross-cutting
  metadata plus an operation-specific `:data` payload.

  The payload's struct type is the discriminator — there is deliberately no
  `kind`/`operation` field, because both are derivable from the payload and
  carrying them would invite drift. `classify/1` is the single site that maps a
  payload struct to its `{operation, kind}`.

  Progress is a *view* of authoritative state, never its source: results and
  metrics are authoritative (an operation's return value), and a terminal
  `*Result` payload carries a copy of that result for consumers.
  """

  alias PropertyDamage.Progress.{
    LoadResult,
    LoadUpdate,
    MutationResult,
    MutationUpdate,
    RunResult,
    RunUpdate
  }

  @type operation :: :test_run | :load_test | :mutation
  @type kind :: :progress | :result

  @type payload ::
          RunUpdate.t()
          | RunResult.t()
          | LoadUpdate.t()
          | LoadResult.t()
          | MutationUpdate.t()
          | MutationResult.t()

  @type t :: %__MODULE__{
          data: payload(),
          at: integer() | nil,
          elapsed_ms: non_neg_integer() | nil,
          run_id: term()
        }

  @enforce_keys [:data]
  defstruct [:data, :at, :elapsed_ms, :run_id]

  @doc """
  Wrap a payload struct in a progress envelope.

  Options: `:at` (system time when projected), `:elapsed_ms` (since the
  operation started), `:run_id` (correlation id for the operation invocation).
  """
  @spec new(payload(), keyword()) :: t()
  def new(data, opts \\ []) when is_struct(data) do
    %__MODULE__{
      data: data,
      at: Keyword.get(opts, :at),
      elapsed_ms: Keyword.get(opts, :elapsed_ms),
      run_id: Keyword.get(opts, :run_id)
    }
  end

  @doc "The operation a progress value belongs to."
  @spec operation(t()) :: operation()
  def operation(%__MODULE__{data: data}), do: elem(classify(data), 0)

  @doc "Whether a progress value is an intermediate update or a terminal result."
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{data: data}), do: elem(classify(data), 1)

  @doc """
  The telemetry event name for a progress value:
  `[:property_damage, operation, kind]`.
  """
  @spec telemetry_event(t()) :: [atom(), ...]
  def telemetry_event(%__MODULE__{data: data}) do
    {operation, kind} = classify(data)
    [:property_damage, operation, kind]
  end

  # The single discriminator-derivation site. New operations add a clause here.
  @spec classify(payload()) :: {operation(), kind()}
  defp classify(%RunUpdate{}), do: {:test_run, :progress}
  defp classify(%RunResult{}), do: {:test_run, :result}
  defp classify(%LoadUpdate{}), do: {:load_test, :progress}
  defp classify(%LoadResult{}), do: {:load_test, :result}
  defp classify(%MutationUpdate{}), do: {:mutation, :progress}
  defp classify(%MutationResult{}), do: {:mutation, :result}
end
