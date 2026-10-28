defmodule PropertyDamage.Log.CapTest do
  # The retry cap as a value (DR-054 decision 13): the gap counts each
  # dropped execution once, whether a newer execution pushed it out or it
  # wrote its first line after the gap already existed.
  use ExUnit.Case, async: true

  alias PropertyDamage.Log.{Cap, Gap, Line}

  defp line(attempt),
    do: %Line{message: "attempt #{attempt}", timestamp: attempt, attempt: attempt}

  defp gap(cap), do: cap |> Cap.lines() |> Enum.find(&is_struct(&1, Gap))

  test "an execution that writes its first line after the gap exists counts as an attempt" do
    cap = Enum.reduce([1, 3, 4], Cap.new(1), &Cap.add(&2, line(&1)))
    assert %Gap{attempts: 1, lines: 1} = gap(cap)

    cap = Cap.add(cap, line(2))

    assert %Gap{attempts: 2, lines: 2} = gap(cap)
    assert Enum.map(Cap.lines(cap) -- [gap(cap)], & &1.attempt) == [1, 4]
  end

  test "a dropped execution that writes again adds lines, not an attempt" do
    cap = Enum.reduce([1, 3, 4, 2, 2, 3], Cap.new(1), &Cap.add(&2, line(&1)))

    assert %Gap{attempts: 2, lines: 4} = gap(cap)
  end
end
