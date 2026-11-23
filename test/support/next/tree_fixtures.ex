# Commands and models whose fields StreamData builds on `tree/2`: the
# level sizes of a tree are the draws of `random_pseudofactors/2`, so these
# fixtures exercise the range draw that the patch routes through
# `uniform_in_range/3`.

defmodule PropertyDamage.Next.Test.Tree.Forest do
  @moduledoc false
  # Two trees in one list: the list's length is drawn before the split that
  # hands each tree its own state.
  use PropertyDamage.Next.Command

  defstruct [:trees]

  def generator(_state, _opts),
    do: %{trees: list_of(tree(integer(0..9), &list_of/1), length: 2)}
end

defmodule PropertyDamage.Next.Test.Tree.Term do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:value]

  def generator(_state, _opts), do: %{value: term()}
end

defmodule PropertyDamage.Next.Test.Tree.Iodata do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:value]

  def generator(_state, _opts), do: %{value: iodata()}
end

defmodule PropertyDamage.Next.Test.Tree.Chardata do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:value]

  def generator(_state, _opts), do: %{value: chardata()}
end

defmodule PropertyDamage.Next.Test.Tree.Single do
  @moduledoc false
  # One tree whose leaves are integers from 0: inside it, only a level size
  # is drawn from a range whose lower bound is 1.
  use PropertyDamage.Next.Command

  defstruct [:tree]

  def generator(_state, _opts), do: %{tree: tree(integer(0..9), &list_of/1)}
end

# One model per command above, named after it: Tree.ForestModel and so on.
for name <- ~w(Forest Term Iodata Chardata Single) do
  command = Module.concat(PropertyDamage.Next.Test.Tree, name)

  defmodule Module.concat(PropertyDamage.Next.Test.Tree, name <> "Model") do
    @moduledoc false
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Fixtures.{EmptyProjection, NullSimulator}

    @command command

    def steps, do: StepSpec.normalize([@command])
    def simulator, do: NullSimulator
    def command_sequence_projection, do: EmptyProjection
  end
end
