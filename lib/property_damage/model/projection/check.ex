defmodule PropertyDamage.Model.Projection.Check do
  @moduledoc """
  One check declared on a projection with `@check` or `@eventually`.

  The `kind` says when the check runs:

    * `:step` - sampled after a command or event during the run (`@check every:`)
    * `:phase` - runs once at a lifecycle boundary, `:startup` or `:teardown`
      (`@check at:`)
    * `:eventually` - polls until a predicate holds (`@eventually`)

  The projection macros derive `kind` once from `type` and `trigger`, so a reader
  matches on `kind` instead of repeating that derivation.

  `type` stays the macro's own tag (`:synchronous` or `:polling`). `trigger` is
  the normalized `@check` timing and is `nil` for an `@eventually` check, which
  carries `eventually` (its poll options) instead.
  """

  @type kind :: :step | :phase | :eventually

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          type: :synchronous | :polling,
          function_name: atom(),
          trigger: map() | nil,
          eventually: map() | nil,
          predicate_source: String.t() | nil,
          invariant_id: atom() | nil,
          invariant_inline?: boolean(),
          invariant_validates?: boolean(),
          invariant_description: String.t() | nil,
          invariant_def_line: non_neg_integer() | nil
        }

  defstruct [
    :name,
    :kind,
    :type,
    :function_name,
    :trigger,
    :eventually,
    :predicate_source,
    :invariant_id,
    :invariant_description,
    :invariant_def_line,
    invariant_inline?: false,
    invariant_validates?: false
  ]

  @doc """
  Builds a check from the fields the projection macros collect, deriving `kind`
  from `type` and `trigger`.
  """
  @spec new(map() | keyword()) :: t()
  def new(fields) do
    fields = Map.new(fields)
    struct!(__MODULE__, Map.put(fields, :kind, kind_for(fields)))
  end

  @doc """
  The kind of a check with the given `type` and `trigger`.
  """
  @spec kind_for(%{required(:type) => atom(), optional(:trigger) => map() | nil}) :: kind()
  def kind_for(%{type: :polling}), do: :eventually
  def kind_for(%{type: :synchronous, trigger: %{type: :at}}), do: :phase
  def kind_for(%{type: :synchronous}), do: :step
end
