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
      %Sequence.Position{section: :setup, offset: 1}
      %Sequence.Position{section: :teardown, offset: 0}

  A leaf of a root's expansion (`c:PropertyDamage.Model.expansions/0`) has the
  section `{:leaf, root}` (the root's index as generated) and its offset within the expansion's leaves, so leaf
  positions never collide with root positions:

      %Sequence.Position{section: {:leaf, 3}, offset: 1}

  The `:setup` and `:teardown` sections hold the model's setup commands
  (`c:PropertyDamage.Model.setup_each/0`) and teardown commands
  (`c:PropertyDamage.Model.teardown_each/0`). They are not roots: a root's
  section is `:prefix`, `{:branch, b}` or `:suffix`.

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
  a specific parallel branch identified by its `branch_id`, or the setup or
  teardown commands.
  """
  @type section ::
          :prefix
          | :suffix
          | {:branch, non_neg_integer()}
          | {:leaf, non_neg_integer()}
          | :setup
          | :teardown

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

  @doc "The position of the setup command at `offset`."
  @spec setup(non_neg_integer()) :: t()
  def setup(offset), do: %__MODULE__{section: :setup, offset: offset}

  @doc "The position of the teardown command at `offset`."
  @spec teardown(non_neg_integer()) :: t()
  def teardown(offset), do: %__MODULE__{section: :teardown, offset: offset}

  @doc """
  The position of leaf `leaf_index` of the expansion the root at `root` ran.

  `root` identifies the root: its index in the sequence as generated, kept
  when a shrink candidate moves the root.
  """
  @spec leaf(non_neg_integer(), non_neg_integer()) :: t()
  def leaf(root, leaf_index), do: %__MODULE__{section: {:leaf, root}, offset: leaf_index}

  @doc "Whether `position` belongs to a root (prefix, branch or suffix) or a root's leaf."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{section: section}), do: section not in [:setup, :teardown]

  @doc """
  Human-readable prose for a position (DR-039).

  The shared phrasing used by the determinism audit and `mix pd.audit`:
  `"prefix position 0"`, `"branch 1 position 2"`, `"suffix position 0"`,
  `"setup position 0"`, `"teardown position 0"`, `"leaf 1 of root 3"`.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{section: :prefix, offset: i}), do: "prefix position #{i}"
  def describe(%__MODULE__{section: {:branch, b}, offset: i}), do: "branch #{b} position #{i}"
  def describe(%__MODULE__{section: :suffix, offset: i}), do: "suffix position #{i}"
  def describe(%__MODULE__{section: :setup, offset: i}), do: "setup position #{i}"
  def describe(%__MODULE__{section: :teardown, offset: i}), do: "teardown position #{i}"
  def describe(%__MODULE__{section: {:leaf, r}, offset: i}), do: "leaf #{i} of root #{r}"
end
