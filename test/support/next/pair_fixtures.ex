# Models whose failure needs two integers to keep a fixed gap, so lowering
# either value alone makes the failure go away and only lowering both by
# the same amount keeps it. The adapter reads its failure rule from plain
# data in its config, so a journal saved here replays in another VM that
# shares only the compiled code.

defmodule PropertyDamage.Next.Test.Pair.Adapter do
  @moduledoc false
  # A system with no behavior of its own: every command answers no events,
  # except one whose `a` exceeds its `b` by exactly the gap.
  #
  # Config keys: `:gap` (an integer; a command with `a - b == gap` fails
  # with `{:error, {:gap, a, b}}`), `:floor` (optional; when given, a
  # command with a `c` field also needs `c >= floor` to fail) and
  # `:recorder` (optional; a pid that receives `{:pair_setup, instance}`
  # when an execution starts and `{:pair_executed, instance, command}` for
  # each command, `instance` being a reference unique to the execution).
  @behaviour PropertyDamage.Next.Adapter

  @impl true
  def setup(config, _runtime) do
    instance = make_ref()
    notify(config, {:pair_setup, instance})
    {:ok, %{instance: instance, config: config}}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(command, _assigns, %{instance: instance, config: config}) do
    notify(config, {:pair_executed, instance, command})
    if fails?(command, config), do: {:error, {:gap, command.a, command.b}}, else: {:ok, []}
  end

  @doc "Whether `command` fails under `config`: the rule `execute/3` applies."
  def fails?(%{a: a, b: b} = command, %{gap: gap} = config) do
    a - b == gap and above_floor?(Map.get(command, :c), Map.get(config, :floor))
  end

  defp above_floor?(_c, nil), do: true
  defp above_floor?(c, floor), do: c >= floor

  defp notify(%{recorder: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_config, _message), do: :ok
end

defmodule PropertyDamage.Next.Test.Pair.Two do
  @moduledoc false
  # Two independent integers over the same range.
  use PropertyDamage.Next.Command

  defstruct [:a, :b]

  def generator(_state, _opts), do: %{a: integer(1..100), b: integer(1..100)}
end

defmodule PropertyDamage.Next.Test.Pair.Three do
  @moduledoc false
  # The two integers of the gap and a third that single lowering can still
  # bring down to the adapter's floor.
  use PropertyDamage.Next.Command

  defstruct [:a, :b, :c]

  def generator(_state, _opts),
    do: %{a: integer(1..100), b: integer(1..100), c: integer(1..100)}
end

defmodule PropertyDamage.Next.Test.Pair.Pinned do
  @moduledoc false
  # Two integers, one of which has a single-value range and so always sits
  # on its lower bound.
  use PropertyDamage.Next.Command

  defstruct [:a, :b]

  def generator(_state, _opts), do: %{a: integer(1..100), b: integer(5..5)}
end

require PropertyDamage.Next.Test.Fixtures.Models

alias PropertyDamage.Next.Test.Fixtures, as: F
alias PropertyDamage.Next.Test.Pair

F.Models.defmodel(Pair.TwoModel, [Pair.Two])
F.Models.defmodel(Pair.ThreeModel, [Pair.Three])
F.Models.defmodel(Pair.PinnedModel, [Pair.Pinned])
