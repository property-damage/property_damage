defmodule PropertyDamage.Sequence do
  @moduledoc """
  Represents a command sequence that may contain parallel branches.

  A sequence consists of three parts:
  - `prefix`: Commands executed sequentially before any branching
  - `branches`: Optional list of parallel branches (each branch is a list of commands)
  - `suffix`: Commands executed sequentially after branches merge

  ## Linear Sequences

  A linear (non-parallel) sequence has `branches: nil` and all commands in `prefix`:

      %Sequence{prefix: [cmd1, cmd2, cmd3], branches: nil, suffix: []}

  Use `Sequence.linear/1` as a convenience constructor:

      Sequence.linear([cmd1, cmd2, cmd3])

  ## Branching Sequences

  A branching sequence has commands before the branch point in `prefix`,
  parallel branches in `branches`, and commands after merge in `suffix`:

      %Sequence{
        prefix: [cmd1, cmd2],
        branches: [[cmd3a, cmd4a], [cmd3b, cmd4b]],
        suffix: [cmd5, cmd6]
      }

  Use `Sequence.branching/3` as a convenience constructor:

      Sequence.branching(
        [cmd1, cmd2],                       # prefix
        [[cmd3a, cmd4a], [cmd3b, cmd4b]],   # branches
        [cmd5, cmd6]                        # suffix
      )

  ## Execution Semantics

  1. Execute `prefix` commands sequentially
  2. If `branches` is not nil:
     a. Fork projection state
     b. Execute each branch in parallel (or interleaved)
     c. Merge results and check for linearizability
  3. Execute `suffix` commands sequentially

  ## Ref Constraints

  - Refs created in `prefix` can be used in any branch
  - Refs created in one branch CANNOT be used in another branch
  - Refs created in branches CAN be used in `suffix` (after merge)
  """

  @type command :: struct()

  @type t :: %__MODULE__{
          prefix: [command()],
          branches: [[command()]] | nil,
          suffix: [command()],
          registry: PropertyDamage.PlaceholderRegistry.t() | nil
        }

  defstruct prefix: [], branches: nil, suffix: [], registry: nil

  @doc """
  Create a linear (non-branching) sequence.

  All commands are placed in the prefix with no branches.

  ## Examples

      iex> seq = PropertyDamage.Sequence.linear([cmd1, cmd2, cmd3])
      iex> seq.prefix
      [cmd1, cmd2, cmd3]
      iex> seq.branches
      nil
  """
  @spec linear([command()]) :: t()
  def linear(commands) when is_list(commands) do
    %__MODULE__{prefix: commands, branches: nil, suffix: []}
  end

  @doc """
  Create a branching sequence with parallel execution.

  ## Parameters

  - `prefix` - Commands to execute before branching
  - `branches` - List of branches, each branch is a list of commands
  - `suffix` - Commands to execute after branches merge (optional)

  ## Examples

      iex> seq = PropertyDamage.Sequence.branching(
      ...>   [setup_cmd],
      ...>   [[branch_a_cmd1, branch_a_cmd2], [branch_b_cmd1]],
      ...>   [cleanup_cmd]
      ...> )
      iex> length(seq.branches)
      2
  """
  @spec branching([command()], [[command()]], [command()]) :: t()
  def branching(prefix, branches, suffix \\ [])
      when is_list(prefix) and is_list(branches) and is_list(suffix) do
    %__MODULE__{prefix: prefix, branches: branches, suffix: suffix}
  end

  @doc """
  Attach a placeholder registry to a sequence (DR-021).

  Used by sequence generation to carry the id-indexed registry + producer-link
  from generation to execution. `to_list/1` deliberately drops it.
  """
  @spec with_registry(t(), PropertyDamage.PlaceholderRegistry.t() | nil) :: t()
  def with_registry(%__MODULE__{} = seq, registry) do
    %{seq | registry: registry}
  end

  @doc """
  Check if a sequence is linear (no parallel branches).

  ## Examples

      iex> PropertyDamage.Sequence.linear?(%Sequence{branches: nil})
      true

      iex> PropertyDamage.Sequence.linear?(%Sequence{branches: [[cmd1], [cmd2]]})
      false
  """
  @spec linear?(t()) :: boolean()
  def linear?(%__MODULE__{branches: nil}), do: true
  def linear?(%__MODULE__{branches: []}), do: true
  def linear?(%__MODULE__{}), do: false

  @doc """
  Check if a sequence has parallel branches.
  """
  @spec branching?(t()) :: boolean()
  def branching?(seq), do: not linear?(seq)

  @doc """
  Get the total number of commands in the sequence.

  Counts commands in prefix + all branches + suffix.

  ## Examples

      iex> seq = PropertyDamage.Sequence.branching([cmd1], [[cmd2, cmd3], [cmd4]], [cmd5])
      iex> PropertyDamage.Sequence.command_count(seq)
      5
  """
  @spec command_count(t()) :: non_neg_integer()
  def command_count(%__MODULE__{prefix: prefix, branches: nil, suffix: suffix}) do
    length(prefix) + length(suffix)
  end

  def command_count(%__MODULE__{prefix: prefix, branches: branches, suffix: suffix}) do
    branch_count = branches |> Enum.map(&length/1) |> Enum.sum()
    length(prefix) + branch_count + length(suffix)
  end

  @doc """
  Get the number of branches (0 for linear sequences).
  """
  @spec branch_count(t()) :: non_neg_integer()
  def branch_count(%__MODULE__{branches: nil}), do: 0
  def branch_count(%__MODULE__{branches: branches}), do: length(branches)

  @doc """
  Convert a sequence to a flat list of commands.

  For linear sequences, returns the prefix.
  For branching sequences, returns prefix ++ (flattened branches) ++ suffix.

  Note: This loses the parallel structure - use only for display/debugging.

  ## Examples

      iex> seq = PropertyDamage.Sequence.branching([cmd1], [[cmd2], [cmd3]], [cmd4])
      iex> PropertyDamage.Sequence.to_list(seq)
      [cmd1, cmd2, cmd3, cmd4]
  """
  @spec to_list(t()) :: [command()]
  def to_list(%__MODULE__{prefix: prefix, branches: nil, suffix: suffix}) do
    prefix ++ suffix
  end

  def to_list(%__MODULE__{prefix: prefix, branches: branches, suffix: suffix}) do
    flattened_branches = List.flatten(branches)
    prefix ++ flattened_branches ++ suffix
  end

  @doc """
  Map a function over all commands in the sequence, preserving structure.

  ## Examples

      iex> seq = PropertyDamage.Sequence.linear([1, 2, 3])
      iex> PropertyDamage.Sequence.map(seq, &(&1 * 2))
      %PropertyDamage.Sequence{prefix: [2, 4, 6], branches: nil, suffix: []}
  """
  @spec map(t(), (command() -> command())) :: t()
  def map(%__MODULE__{prefix: prefix, branches: nil, suffix: suffix} = seq, fun) do
    %__MODULE__{
      prefix: Enum.map(prefix, fun),
      branches: nil,
      suffix: Enum.map(suffix, fun),
      registry: seq.registry
    }
  end

  def map(%__MODULE__{prefix: prefix, branches: branches, suffix: suffix} = seq, fun) do
    %__MODULE__{
      prefix: Enum.map(prefix, fun),
      branches: Enum.map(branches, fn branch -> Enum.map(branch, fun) end),
      suffix: Enum.map(suffix, fun),
      registry: seq.registry
    }
  end

  @doc """
  Filter commands in the sequence, preserving structure.

  Empty branches are removed. If all branches become empty, converts to linear.
  """
  @spec filter(t(), (command() -> boolean())) :: t()
  def filter(%__MODULE__{prefix: prefix, branches: nil, suffix: suffix} = seq, pred) do
    %__MODULE__{
      prefix: Enum.filter(prefix, pred),
      branches: nil,
      suffix: Enum.filter(suffix, pred),
      registry: seq.registry
    }
  end

  def filter(%__MODULE__{prefix: prefix, branches: branches, suffix: suffix} = seq, pred) do
    filtered_prefix = Enum.filter(prefix, pred)
    filtered_suffix = Enum.filter(suffix, pred)

    filtered_branches =
      branches
      |> Enum.map(fn branch -> Enum.filter(branch, pred) end)
      |> Enum.reject(&Enum.empty?/1)

    case filtered_branches do
      [] ->
        # No branches left, convert to linear
        %__MODULE__{
          prefix: filtered_prefix,
          branches: nil,
          suffix: filtered_suffix,
          registry: seq.registry
        }

      _ ->
        %__MODULE__{
          prefix: filtered_prefix,
          branches: filtered_branches,
          suffix: filtered_suffix,
          registry: seq.registry
        }
    end
  end

  @doc """
  Append a command to the end of the sequence.

  For linear sequences, appends to prefix.
  For branching sequences, appends to suffix.
  """
  @spec append(t(), command()) :: t()
  def append(%__MODULE__{branches: nil} = seq, command) do
    %{seq | prefix: seq.prefix ++ [command]}
  end

  def append(%__MODULE__{} = seq, command) do
    %{seq | suffix: seq.suffix ++ [command]}
  end

  @doc """
  Prepend a command to the beginning of the sequence.
  """
  @spec prepend(t(), command()) :: t()
  def prepend(%__MODULE__{} = seq, command) do
    %{seq | prefix: [command | seq.prefix]}
  end

  @doc """
  Add a new branch to the sequence.

  If the sequence is linear, converts it to branching with the existing
  commands as prefix and the new branch.
  """
  @spec add_branch(t(), [command()]) :: t()
  def add_branch(%__MODULE__{branches: nil, prefix: prefix}, branch_commands) do
    # Convert linear to branching: existing commands become prefix
    # and we start with one branch
    %__MODULE__{prefix: prefix, branches: [branch_commands], suffix: []}
  end

  def add_branch(%__MODULE__{branches: branches} = seq, branch_commands) do
    %{seq | branches: branches ++ [branch_commands]}
  end

  @doc """
  Generate all possible linearizations of a branching sequence.

  For a sequence with N branches, generates all valid interleaving orderings
  of the branch commands, preserving the order within each branch.

  Returns a list of linear sequences, each representing one possible
  sequential execution order.

  For linear sequences, returns a list containing just that sequence.

  ## Complexity

  For K branches with N total commands, worst case is O(N! / (n1! * n2! * ... * nk!))
  where ni is the length of branch i.
  """
  @spec linearizations(t()) :: [t()]
  def linearizations(%__MODULE__{branches: nil} = seq), do: [seq]

  def linearizations(%__MODULE__{prefix: prefix, branches: branches, suffix: suffix}) do
    # Generate all interleavings of the branches
    interleavings = interleave_all(branches)

    Enum.map(interleavings, fn interleaved ->
      linear(prefix ++ interleaved ++ suffix)
    end)
  end

  # Generate all possible interleavings of multiple lists
  defp interleave_all([]), do: [[]]
  defp interleave_all([single]), do: [single]

  defp interleave_all(lists) do
    do_interleave(lists, [])
  end

  defp do_interleave(lists, acc) do
    # Filter out empty lists
    non_empty = Enum.reject(lists, &Enum.empty?/1)

    case non_empty do
      [] ->
        # All lists exhausted, return accumulated interleaving
        [Enum.reverse(acc)]

      _ ->
        # For each non-empty list, try taking its first element
        non_empty
        |> Enum.with_index()
        |> Enum.flat_map(fn {[head | tail], idx} ->
          # Replace this list with its tail
          new_lists = List.replace_at(non_empty, idx, tail)
          do_interleave(new_lists, [head | acc])
        end)
    end
  end
end
