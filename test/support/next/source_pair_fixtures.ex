# A model whose failure needs two values inside one nested field to keep a
# fixed gap. On the engine that records each range draw of a StreamData
# value, both values are positions of one entry, so only a candidate that
# lowers two positions of that entry by the same amount keeps the failure.

defmodule PropertyDamage.Next.Test.Pair.Nested do
  @moduledoc false
  # One map of two integers over the same range. The keyword form of
  # fixed_map draws `a` before `b`.
  use PropertyDamage.Next.Command

  defstruct [:pair]

  def generator(_state, _opts),
    do: %{pair: fixed_map(a: integer(1..100), b: integer(1..100))}
end

require PropertyDamage.Next.Test.Fixtures.Models

PropertyDamage.Next.Test.Fixtures.Models.defmodel(
  PropertyDamage.Next.Test.Pair.NestedModel,
  [PropertyDamage.Next.Test.Pair.Nested]
)
