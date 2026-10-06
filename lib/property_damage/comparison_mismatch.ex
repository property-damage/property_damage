# A mismatch is a finding, not an error raised by the framework, so the name
# carries no `Error` suffix.
# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule PropertyDamage.ComparisonMismatch do
  @moduledoc """
  The default detail of a disagreement between two compared values.

  A `using:` predicate (on `@compare` or on `stutter:`) that returns `false`
  produces one holding both values, and one that returns
  `{:mismatch, "text"}` produces one holding the text. `left` is the first
  value the predicate was called with and `right` the second: for `@compare`
  the reference's value and the variant's, for stutter the original events
  and the retry events.

  `Exception.message/1` returns the text when there is one, and otherwise
  renders both values.
  """

  defexception [:left, :right, :message]

  @type t :: %__MODULE__{left: term(), right: term(), message: String.t() | nil}

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message

  def message(%__MODULE__{left: left, right: right}) do
    "left:  " <> inspect(left, pretty: true) <> "\nright: " <> inspect(right, pretty: true)
  end
end
