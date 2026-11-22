# Small command modules, models and helpers shared by the new engine's tests.

defmodule PropertyDamage.Next.Test.Fixtures.NullSimulator do
  @moduledoc false
  @behaviour PropertyDamage.Model.Simulator

  @impl true
  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Next.Test.Fixtures.EmptyProjection do
  @moduledoc false
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _event), do: state
end

defmodule PropertyDamage.Next.Test.Fixtures.Probe do
  @moduledoc false
  # One field per kind of draw: an integer, a member, a boolean, a StreamData
  # generator, a field that depends on another, and a mint. `untouched` is
  # not in the map, so it keeps its default.
  use PropertyDamage.Next.Command

  defstruct [:count, :color, :flag, :label, :size, :token, untouched: :default]

  def colors, do: [:red, :green, :blue]

  def generator(_state, _opts) do
    %{
      count: integer(1..9),
      color: member_of(colors()),
      flag: boolean(),
      label: string(:alphanumeric, min_length: 1, max_length: 6),
      size: from(:count, fn c -> integer(c..(c + 3)) end),
      token: mint_per_run({:hex, 8})
    }
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.Chain do
  @moduledoc false
  # Dependent fields: one source, a list of sources, and a chain written as
  # separate fields.
  use PropertyDamage.Next.Command

  defstruct [:base, :other, :echo, :sum, :next]

  def generator(_state, _opts) do
    %{
      base: integer(1..5),
      other: integer(1..5),
      echo: from(:base, fn b -> integer(b..b) end),
      sum:
        from([:base, :other], fn %{base: b, other: o} = fields when map_size(fields) == 2 ->
          integer((b + o)..(b + o))
        end),
      next: from(:echo, fn e -> integer(e..(e + 1)) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.OptsEcho do
  @moduledoc false
  # Draws the options it receives, so a test can read them off the command.
  use PropertyDamage.Next.Command

  defstruct [:seen]

  def generator(_state, opts), do: %{seen: member_of([opts])}
end

defmodule PropertyDamage.Next.Test.Fixtures.Plain do
  @moduledoc false
  # A command with nothing to draw: the struct and its defaults.
  use PropertyDamage.Next.Command

  defstruct note: :empty
end

defmodule PropertyDamage.Next.Test.Fixtures.NotACommand do
  @moduledoc false
  defstruct [:amount]
end

defmodule PropertyDamage.Next.Test.Fixtures.NumberField do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: 5}
end

defmodule PropertyDamage.Next.Test.Fixtures.RangeField do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %{amount: 1..5}
end

defmodule PropertyDamage.Next.Test.Fixtures.StructGenerator do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: %__MODULE__{amount: integer(1..5)}
end

defmodule PropertyDamage.Next.Test.Fixtures.SingleGenerator do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:amount]

  def generator(_state, _opts), do: StreamData.fixed_map(%{amount: StreamData.integer(1..5)})
end

defmodule PropertyDamage.Next.Test.Fixtures.FromReturnsFrom do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:base, :derived]

  def generator(_state, _opts) do
    %{
      base: integer(1..5),
      derived: from(:base, fn _b -> from(:base, fn b -> integer(b..b) end) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.UnknownFrom do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:base, :derived]

  def generator(_state, _opts) do
    %{base: integer(1..5), derived: from(:missing_source, fn m -> integer(m..m) end)}
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.CycleFrom do
  @moduledoc false
  use PropertyDamage.Next.Command

  defstruct [:left_side, :right_side]

  def generator(_state, _opts) do
    %{
      left_side: from(:right_side, fn r -> integer(r..r) end),
      right_side: from(:left_side, fn l -> integer(l..l) end)
    }
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.PlainFrom do
  @moduledoc false
  # A dependent field whose function returns a plain StreamData generator,
  # which PD's own engine cannot fit when the source changes.
  use PropertyDamage.Next.Command

  defstruct [:base, :derived]

  def generator(_state, _opts) do
    %{base: integer(1..5), derived: from(:base, fn b -> StreamData.integer(1..b) end)}
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.DelegatedFrom do
  @moduledoc false
  # As `PlainFrom`, with a delegated generator from PD's generator module.
  use PropertyDamage.Next.Command

  defstruct [:base, :derived]

  def generator(_state, _opts) do
    %{base: integer(1..5), derived: from(:base, fn b -> list_of(integer(1..b)) end)}
  end
end

defmodule PropertyDamage.Next.Test.Fixtures.LowestEngine do
  @moduledoc false
  # An engine that draws the lowest value of every PD description and leaves
  # every other generator to PD's own engine.
  @behaviour PropertyDamage.Next.Engine

  alias PropertyDamage.Next.Engine.Native
  alias PropertyDamage.Next.Gen

  @impl true
  def draw(_journal, _key, %Gen{kind: :integer, domain: range}, _seed),
    do: {range.first, {:integer, range.first, range}}

  def draw(_journal, _key, %Gen{kind: :member, domain: [first | _]}, _seed),
    do: {first, {:member, first, 0}}

  def draw(journal, key, generator, seed), do: Native.draw(journal, key, generator, seed)
end

defmodule PropertyDamage.Next.Test.Leak do
  @moduledoc false
  # Finds PD-internal terms inside a value that reached the system under
  # test: placeholders, mint and external markers, steps, specs, journals,
  # runtime handles, and `{lane, slot}` keys (a pair of integers, which no
  # command of the running example holds).

  @internal [
    PropertyDamage.Next.Placeholder,
    PropertyDamage.Next.Step,
    PropertyDamage.Next.StepSpec,
    PropertyDamage.Next.Journal,
    PropertyDamage.Next.Runtime,
    PropertyDamage.Next.From,
    PropertyDamage.Next.Gen,
    PropertyDamage.Placeholder,
    PropertyDamage.Mint,
    PropertyDamage.External
  ]

  @doc "Every PD-internal subterm of `term`, outermost first."
  def find(term), do: term |> scan([]) |> Enum.reverse()

  defp scan(%{__struct__: module} = term, acc) when module in @internal, do: [term | acc]
  defp scan(%{__struct__: _} = term, acc), do: term |> Map.from_struct() |> scan(acc)

  defp scan(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {k, v}, acc -> scan(v, scan(k, acc)) end)

  defp scan(list, acc) when is_list(list), do: Enum.reduce(list, acc, &scan/2)

  defp scan({a, b} = key, acc) when is_integer(a) and is_integer(b), do: [key | acc]

  defp scan(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &scan/2)

  defp scan(_other, acc), do: acc
end

defmodule PropertyDamage.Next.Test.Terms do
  @moduledoc false
  # Helpers for asserting on terms whose exact shape the surface leaves open.

  @doc "Whether `needle` occurs anywhere inside `term` (or is `term`)."
  def mentions?(term, needle) when term === needle, do: true

  def mentions?(%{__struct__: _} = term, needle),
    do: term |> Map.from_struct() |> mentions?(needle)

  def mentions?(%{} = map, needle),
    do: Enum.any?(map, fn {k, v} -> mentions?(k, needle) or mentions?(v, needle) end)

  def mentions?(list, needle) when is_list(list), do: Enum.any?(list, &mentions?(&1, needle))

  def mentions?(tuple, needle) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> mentions?(needle)

  def mentions?(_term, _needle), do: false

  @doc "The exception `fun` raises, or flunks if it returns."
  def raised(fun) do
    fun.()
    ExUnit.Assertions.flunk("expected an exception, but the call returned")
  rescue
    exception in [ExUnit.AssertionError] -> reraise exception, __STACKTRACE__
    exception -> exception
  end

  @doc "The steps of a plan, whether given the plan struct or its step list."
  def steps_of(%PropertyDamage.Next.Plan{steps: steps}), do: steps
  def steps_of(steps) when is_list(steps), do: steps
end
