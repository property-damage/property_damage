defmodule PropertyDamage.Sequence.Position do
  @moduledoc """
  The structured location of a command within a `PropertyDamage.Sequence`.

  A position names *which section* of the sequence a command lives in and its
  *offset within that section*. This gives every command a canonical identity
  that is unambiguous across parallel branches: two commands in different
  branches can share an executor `command_index`, but never a position.

      %Sequence.Position{section: :prefix, offset: 0}
      %Sequence.Position{section: {:branch, 1}, offset: 2}
      %Sequence.Position{section: :suffix, offset: 0}

  It reifies the executor's raw `current_position` tuples
  (`{:prefix, i}` / `{:branch, b, i}` / `{:suffix, i}`, DR-021) as a first-class
  type, and is intended to be the single position vocabulary shared across the
  failure-query interface and the placeholder registry rather than each
  re-encoding the tuple.

  Distinct from a command's *flattened index* (its `Sequence.to_list/1`
  reading-order ordinal): a position is not derivable from a lone flattened
  index and vice versa. `Sequence.indexed/1` owns the contextual mapping between
  the two, and `Sequence.position_at/3` resolves an executor command index to a
  position.
  """

  @typedoc """
  Which section of a sequence a command lives in: the `:prefix`, the `:suffix`,
  or a specific parallel branch identified by its `branch_id`.
  """
  @type section :: :prefix | :suffix | {:branch, non_neg_integer()}

  @type t :: %__MODULE__{
          section: section(),
          offset: non_neg_integer()
        }

  @enforce_keys [:section, :offset]
  defstruct [:section, :offset]

  @typedoc "The executor's raw `current_position` tuple form (DR-021)."
  @type tuple_form ::
          {:prefix, non_neg_integer()}
          | {:suffix, non_neg_integer()}
          | {:branch, non_neg_integer(), non_neg_integer()}

  @doc """
  Reify the executor's raw `current_position` tuple as a `Position`.

  Inverse of the tuple encoding the executor uses internally. `nil` (no
  position set) passes through as `nil`.
  """
  @spec from_tuple(tuple_form() | nil) :: t() | nil
  def from_tuple(nil), do: nil
  def from_tuple({:prefix, offset}), do: %__MODULE__{section: :prefix, offset: offset}
  def from_tuple({:suffix, offset}), do: %__MODULE__{section: :suffix, offset: offset}

  def from_tuple({:branch, branch_id, offset}),
    do: %__MODULE__{section: {:branch, branch_id}, offset: offset}
end
