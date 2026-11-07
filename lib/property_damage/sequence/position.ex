defmodule PropertyDamage.Sequence.Position do
  @moduledoc """
  The structured location of a command within a `PropertyDamage.Sequence`.

  A position names *which section* of the sequence a command lives in and its
  *offset within that section*. This gives every command a canonical identity:
  a root and a setup command can share an offset, but never a position.

      %Sequence.Position{section: :prefix, offset: 0}
      %Sequence.Position{section: :setup, offset: 1}
      %Sequence.Position{section: :teardown, offset: 0}

  A leaf of a root's expansion (`c:PropertyDamage.Model.expansions/0`) has the
  section `{:leaf, root}` (the root's index as generated) and its offset within the expansion's leaves, so leaf
  positions never collide with root positions:

      %Sequence.Position{section: {:leaf, 3}, offset: 1}

  The `:setup` and `:teardown` sections hold the model's setup commands
  (`c:PropertyDamage.Model.setup_each/0`) and teardown commands
  (`c:PropertyDamage.Model.teardown_each/0`). They are not roots: a root's
  section is `:prefix`.

  This is *the* position vocabulary (DR-039): the whole framework speaks it, from
  the generator's minting and the executor's `current_position` through the
  placeholder registry, the shrinker's remap, the determinism audit, and the
  failure-query interface. There is no raw-tuple encoding to reify anymore; use
  the `prefix/1`, `setup/1`, `teardown/1` and `leaf/2` constructors to mint one.

  Distinct from a command's index (its `Sequence.to_list/1` ordinal):
  `Sequence.indexed/1` pairs the two, and `Sequence.position_at/2` resolves an
  executor command index to a position.
  """

  @typedoc """
  Which section of a sequence a command lives in: the `:prefix` (the roots),
  the leaves of one root's expansion, or the setup or teardown commands.
  """
  @type section ::
          :prefix
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

  @doc "Whether `position` belongs to a root or a root's leaf."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{section: section}), do: section not in [:setup, :teardown]

  @doc """
  Human-readable prose for a position (DR-039).

  The shared phrasing used by the determinism audit and `mix pd.audit`:
  `"prefix position 0"`, `"setup position 0"`, `"teardown position 0"`, `"leaf 1 of root 3"`.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{section: :prefix, offset: i}), do: "prefix position #{i}"
  def describe(%__MODULE__{section: :setup, offset: i}), do: "setup position #{i}"
  def describe(%__MODULE__{section: :teardown, offset: i}), do: "teardown position #{i}"
  def describe(%__MODULE__{section: {:leaf, r}, offset: i}), do: "leaf #{i} of root #{r}"

  @doc """
  The label the failure report prints for the command at `position` (DR-055,
  DR-056).

  A root is `[i]`, a leaf `[i.j]` under its root, and a setup or teardown command `[setup i]` or
  `[teardown i]`. Every index counts from 0.

  `root` is the reading-order index (see `PropertyDamage.Sequence.indexed/1`)
  of the root the command is or belongs to. A leaf needs it, because its
  position names the root by its index as generated, which shrinking does not
  renumber: a leaf of the root printed as `[0]` is `[0.1]`, never `[2.1]`.
  Without `root`, a leaf position raises an `ArgumentError`. The other
  sections ignore `root`.

      iex> alias PropertyDamage.Sequence.Position
      iex> Position.label(Position.prefix(1))
      "[1]"
      iex> Position.label(Position.leaf(2, 1), 0)
      "[0.1]"
      iex> Position.label(Position.setup(1))
      "[setup 1]"
      iex> Position.label(Position.teardown(0))
      "[teardown 0]"
  """
  @spec label(t(), non_neg_integer() | nil) :: String.t()
  def label(position, root \\ nil)
  def label(%__MODULE__{section: :prefix, offset: i}, _root), do: "[#{i}]"
  def label(%__MODULE__{section: :setup, offset: i}, _root), do: "[setup #{i}]"
  def label(%__MODULE__{section: :teardown, offset: i}, _root), do: "[teardown #{i}]"

  def label(%__MODULE__{section: {:leaf, _id}, offset: j}, root) when is_integer(root),
    do: "[#{root}.#{j}]"

  def label(%__MODULE__{} = position, nil) do
    raise ArgumentError,
          "the label of #{describe(position)} needs the reading-order index of its root"
  end
end
