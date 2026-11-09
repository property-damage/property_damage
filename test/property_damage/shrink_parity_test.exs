defmodule PropertyDamage.ShrinkParityTest do
  @moduledoc """
  Pins how much work the shrinker does for a fixed seed set.

  `PropertyDamage.SeedCharacterizationTest` pins the shrunk sequence of each
  seed. This test pins the number of candidates the shrinker tried and why it
  stopped, so a change to the order or the count of candidates fails here even
  when it reaches the same sequence. After an intended change to the shrinker,
  regenerate the fixture with `test/fixtures/shrink_parity/generate.exs` and read
  the diff.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.SeedCharacterization, as: S
  alias PropertyDamage.Test.ShrinkParity

  setup_all do
    {:ok, fixture: ShrinkParity.read!()}
  end

  for name <- S.case_names() do
    @case_name name

    describe "#{name}" do
      test "the fixture covers the seed set and holds failing seeds", %{fixture: fixture} do
        observed = Map.fetch!(fixture, @case_name)

        assert Enum.sort(Map.keys(observed)) == Enum.sort(S.seeds(@case_name))
        failing = observed |> Map.values() |> Enum.reject(&is_nil/1)

        assert failing != []
        assert Enum.any?(Map.values(observed), &is_nil/1), "control: some seed passes"

        # A fixture of one repeated count would not tell one candidate order
        # from another.
        assert failing |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() > 3
        assert Enum.all?(failing, fn {iterations, _stop} -> iterations > 0 end)
      end

      for seed <- S.seeds(name) do
        @seed seed

        test "seed #{seed} shrinks with the recorded iterations and stop", %{fixture: fixture} do
          expected = fixture |> Map.fetch!(@case_name) |> Map.fetch!(@seed)

          assert ShrinkParity.observe(@case_name, @seed) == expected
        end
      end
    end
  end
end
