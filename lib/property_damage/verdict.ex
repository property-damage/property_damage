defmodule PropertyDamage.Verdict do
  @moduledoc """
  Reads a verdict: the value a `@check` returns, an `@eventually` predicate
  returns, or a `using:` relation returns (DR-052).

  The three kinds share one grammar, so a reader learns one rule:

  | Return | `@check` | `@eventually` predicate | `using:` relation |
  |--------|----------|-------------------------|-------------------|
  | truthy | pass | satisfied | agree |
  | `nil`, `false` | fail, generic message | not yet | disagree, both values |
  | `{:fail, "text"}` | fail, that message | never: fail now | disagree, that message |
  | `{:fail, %Exception{}}` | fail, that exception | never: fail now | disagree, that exception |
  | bare exception struct, `{:error, _}`, `{:mismatch, _}` | fail, with the grammar nudge | same | same |

  A raise is a failure in all three kinds; the caller catches it, since
  reading a value cannot see one.

  `{:mismatch, _}` is the retired relation form of DR-046. It is truthy, so
  without the nudge it would agree silently. `:match`, its retired partner, is
  truthy and meant agreement, so it passes as it always did.

  `{:fail, reason}` is the returned form of `PropertyDamage.fail!/2`: raising
  is the early exit, returning is the tail, and both produce the same
  `PropertyDamage.CheckFailed`. A verdict is a final value, never a boolean:
  `&&`, `||`, `!` and `Enum.all?/2` see a `{:fail, _}` as truthy, so
  sub-checks compose with `with true <- a(state), true <- b(state), do: true`.

  `read/2` returns one of three internal tags, the same for every kind:

    * `:pass` for a truthy verdict;
    * `:falsy` for `nil` or `false`, which each caller reads its own way
      (a failure, "not yet", or a disagreement holding both values);
    * `{:fail, exception}` for a reasoned failure and for a value that is not
      a verdict. A string reason becomes a `PropertyDamage.CheckFailed` for a
      check or a predicate and a `PropertyDamage.ComparisonMismatch` for a
      relation; an exception reason is kept as it is.
  """

  alias PropertyDamage.CheckFailed
  alias PropertyDamage.ComparisonMismatch

  @typedoc """
  What returned the verdict: a check or a predicate (`:check`), or a relation
  called with `left` and `right` (`{:relation, left, right}`).
  """
  @type kind :: :check | {:relation, left :: term(), right :: term()}

  @typedoc "The reading of a verdict."
  @type t :: :pass | :falsy | {:fail, Exception.t()}

  @nudge "a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"

  @doc """
  Read the verdict `value` returned by a check, a predicate or a relation.

  `kind` decides how a string reason is wrapped; it defaults to `:check`.

  ## Examples

  A truthy value passes:

      iex> PropertyDamage.Verdict.read(true)
      :pass
      iex> PropertyDamage.Verdict.read(:ok)
      :pass

  `nil` and `false` are falsy:

      iex> PropertyDamage.Verdict.read(nil)
      :falsy
      iex> PropertyDamage.Verdict.read(false)
      :falsy

  `{:fail, "text"}` fails with that message:

      iex> PropertyDamage.Verdict.read({:fail, "net below fees"})
      {:fail, %PropertyDamage.CheckFailed{message: "net below fees", data: %{}}}

  `{:fail, %Exception{}}` fails with that exception:

      iex> PropertyDamage.Verdict.read({:fail, %ArgumentError{message: "bad"}})
      {:fail, %ArgumentError{message: "bad"}}

  A bare exception struct, an `{:error, _}` tuple and the retired
  `{:mismatch, _}` are not verdicts; they fail with the grammar nudge,
  carrying the value:

      iex> {:fail, failure} = PropertyDamage.Verdict.read(%ArgumentError{message: "bad"})
      iex> Exception.message(failure)
      "returned %ArgumentError{message: \\"bad\\"}, which is not a verdict; a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"

      iex> {:fail, failure} = PropertyDamage.Verdict.read({:error, :timeout})
      iex> Exception.message(failure)
      "returned {:error, :timeout}, which is not a verdict; a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"

      iex> {:fail, failure} = PropertyDamage.Verdict.read({:mismatch, "settled differs"})
      iex> Exception.message(failure)
      "returned {:mismatch, \\"settled differs\\"}, which is not a verdict; a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"
  """
  @spec read(term(), kind()) :: t()
  def read(value, kind \\ :check)

  def read(value, _kind) when value in [nil, false], do: :falsy
  def read({:fail, exception}, _kind) when is_exception(exception), do: {:fail, exception}
  def read({:fail, text}, kind) when is_binary(text), do: {:fail, wrap(text, kind)}
  def read({:fail, other}, kind), do: {:fail, wrap(inspect(other), kind)}

  def read({:error, _reason} = value, kind), do: {:fail, wrap(nudge(value), kind)}
  def read({:mismatch, _detail} = value, kind), do: {:fail, wrap(nudge(value), kind)}
  def read(value, kind) when is_exception(value), do: {:fail, wrap(nudge(value), kind)}

  def read(_value, _kind), do: :pass

  @doc false
  # The verdict of a `@check` function named `name` that returned `value`:
  # `:pass`, or `{:fail, exception}` where a falsy return fails with the
  # message of DR-052 item 4.
  @spec check(term(), atom()) :: :pass | {:fail, Exception.t()}
  def check(value, name) do
    case read(value) do
      :falsy ->
        {:fail,
         %CheckFailed{
           message:
             "check `#{name}` returned `#{inspect(value)}`; a check passes by returning a " <>
               "truthy value: a predicate, `condition or fail!(...)`, or a body that ends " <>
               "with `:ok`",
           data: %{}
         }}

      reading ->
        reading
    end
  end

  @doc false
  # The verdict of a relation that answered `answer` for `left` and `right`:
  # `:agree`, or `{:disagree, exception}` where a falsy answer disagrees
  # holding both values.
  @spec relation(term(), term(), term()) :: :agree | {:disagree, Exception.t()}
  def relation(answer, left, right) do
    case read(answer, {:relation, left, right}) do
      :pass -> :agree
      :falsy -> {:disagree, %ComparisonMismatch{left: left, right: right}}
      {:fail, exception} -> {:disagree, exception}
    end
  end

  defp wrap(text, :check), do: %CheckFailed{message: text, data: %{}}

  defp wrap(text, {:relation, left, right}),
    do: %ComparisonMismatch{left: left, right: right, message: text}

  defp nudge(value), do: "returned #{inspect(value)}, which is not a verdict; " <> @nudge
end
