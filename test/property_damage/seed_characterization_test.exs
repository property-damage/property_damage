defmodule PropertyDamage.SeedCharacterizationTest do
  @moduledoc """
  Pins what a linear run does for a fixed seed set.

  For each seed of two seeded-defect models, the run's generated plans, outcome,
  events, failure and shrunk reproduction, rendered as plain data, must equal
  the golden file written by `test/fixtures/seed_characterization/generate.exs`.
  A refactor that leaves linear runs alone leaves every golden value alone;
  after an intended change to generation or shrinking, regenerate the files and
  read the diff.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.SeedCharacterization, as: S

  @sections [:outcome, :plans, :events, :failure, :original, :shrunk]

  for name <- S.case_names() do
    @case_name name

    describe "#{name}" do
      setup do
        {:ok, golden: S.golden_path(@case_name) |> S.read_golden!() |> Map.new()}
      end

      test "the golden file covers the seed set", %{golden: golden} do
        assert Enum.sort(Map.keys(golden)) == Enum.sort(S.seeds(@case_name))

        outcomes = golden |> Map.values() |> Enum.map(& &1.outcome)
        assert :fail in outcomes
      end

      for seed <- S.seeds(name) do
        @seed seed

        test "seed #{seed} renders as the golden run", %{golden: golden} do
          actual = S.render_run(@case_name, @seed)
          expected = Map.fetch!(golden, @seed)

          for section <- @sections do
            assert Map.fetch!(actual, section) == Map.fetch!(expected, section),
                   "#{@case_name} seed #{@seed}: #{section} differs from the golden file"
          end
        end
      end
    end
  end
end
