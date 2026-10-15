defmodule PropertyDamage.GeneratorFieldOrderTest do
  # A map's iteration order depends on the VM: for a small map with atom keys
  # it can follow the order in which the VM created those atoms. A command's
  # fields must draw the same values for a seed in every VM, so the draw
  # order cannot come from iterating a map. This test creates its own atoms
  # in a chosen order, which makes the creation order deterministic here.
  use ExUnit.Case, async: true

  alias PropertyDamage.Generator

  @seed 20_261_015

  # Atoms that exist nowhere else: created in `names` order on first use.
  defp fresh_atoms(names), do: Enum.map(names, &String.to_atom("pd_field_order_" <> &1))

  defp draw(keys) do
    keys
    |> Map.new(fn key -> {key, StreamData.integer(1..1_000_000)} end)
    |> Generator.merge_overrides(%{})
    |> StreamData.fixed_map()
    |> Generator.generate_value(@seed)
  end

  defp by_sorted_key(value), do: value |> Enum.sort() |> Enum.map(fn {_key, v} -> v end)

  test "a command's fields draw the same values whatever order the VM created their keys in" do
    # Created against text order: "z" before "a".
    [z_late, a_late] = fresh_atoms(["zz_against_text", "aa_against_text"])
    # Created in text order: "a" before "z".
    [a_early, z_early] = fresh_atoms(["aa_with_text", "zz_with_text"])

    against_text = draw([a_late, z_late])
    with_text = draw([a_early, z_early])

    assert by_sorted_key(against_text) == by_sorted_key(with_text)
  end
end
