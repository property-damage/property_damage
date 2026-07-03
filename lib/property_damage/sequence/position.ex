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

  This is *the* position vocabulary (DR-039): the whole framework speaks it, from
  the generator's minting and the executor's `current_position` through the
  placeholder registry, the shrinker's remap, the determinism audit, and the
  failure-query interface. There is no raw-tuple encoding to reify anymore; use
  the `prefix/1`, `branch/2`, and `suffix/1` constructors to mint one.

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

  @doc "A prefix position at `offset` (DR-039)."
  @spec prefix(non_neg_integer()) :: t()
  def prefix(offset), do: %__MODULE__{section: :prefix, offset: offset}

  @doc "A position in branch `branch_id` at `offset` (DR-039)."
  @spec branch(non_neg_integer(), non_neg_integer()) :: t()
  def branch(branch_id, offset), do: %__MODULE__{section: {:branch, branch_id}, offset: offset}

  @doc "A suffix position at `offset` (DR-039)."
  @spec suffix(non_neg_integer()) :: t()
  def suffix(offset), do: %__MODULE__{section: :suffix, offset: offset}

  @doc """
  Human-readable prose for a position (DR-039).

  The shared phrasing used by the determinism audit and `mix pd.audit`:
  `"prefix position 0"`, `"branch 1 position 2"`, `"suffix position 0"`.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{section: :prefix, offset: i}), do: "prefix position #{i}"
  def describe(%__MODULE__{section: {:branch, b}, offset: i}), do: "branch #{b} position #{i}"
  def describe(%__MODULE__{section: :suffix, offset: i}), do: "suffix position #{i}"
end
