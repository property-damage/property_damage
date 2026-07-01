defmodule PropertyDamage.NemesisGenerationTest do
  @moduledoc """
  DR-031: the sequence generator dispatches the Nemesis generation callbacks.

  A nemesis module listed in `commands/0` is selected by weight alongside ordinary
  commands and produces an instance via `new!/2` (not `generator/1`, which nemeses
  do not implement), filtered by `precondition/1`.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.Generator
  alias PropertyDamage.Sequence
  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Projections.ModelState

  # A hermetic nemesis with a generation surface (new!/2) and a precondition.
  defmodule GenNemesis do
    @behaviour PropertyDamage.Nemesis

    defstruct severity: 1

    @impl true
    def precondition(_state), do: true

    @impl true
    def new!(_state, overrides) do
      StreamData.bind(StreamData.integer(1..5), fn severity ->
        StreamData.constant(%__MODULE__{severity: Map.get(overrides, :severity, severity)})
      end)
    end

    @impl true
    def inject(%__MODULE__{}, _ctx), do: {:ok, []}

    @impl true
    def restore(%__MODULE__{}, _ctx), do: {:ok, []}
  end

  # Same shape, but its precondition is unmet for the generation start state
  # (ModelState.init has no items, and CreateItem produces none during the
  # simulator-less symbolic phase), so it must never be selected.
  defmodule UnmetNemesis do
    @behaviour PropertyDamage.Nemesis

    defstruct []

    @impl true
    def precondition(state), do: map_size(Map.get(state, :items, %{})) > 0

    @impl true
    def new!(_state, _overrides), do: StreamData.constant(%__MODULE__{})

    @impl true
    def inject(%__MODULE__{}, _ctx), do: {:ok, []}

    @impl true
    def restore(%__MODULE__{}, _ctx), do: {:ok, []}
  end

  # A nemesis without new!/2 cannot be generated from the model.
  defmodule NoGenNemesis do
    @behaviour PropertyDamage.Nemesis

    defstruct []

    @impl true
    def precondition(_state), do: true

    @impl true
    def inject(%__MODULE__{}, _ctx), do: {:ok, []}

    @impl true
    def restore(%__MODULE__{}, _ctx), do: {:ok, []}
  end

  defmodule GenModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [{CreateItem, weight: 1}, {PropertyDamage.NemesisGenerationTest.GenNemesis, weight: 50}]
    end

    @impl true
    def command_sequence_projection, do: ModelState
  end

  defmodule UnmetModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [{CreateItem, weight: 1}, {PropertyDamage.NemesisGenerationTest.UnmetNemesis, weight: 50}]
    end

    @impl true
    def command_sequence_projection, do: ModelState
  end

  defmodule NoGenModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [{CreateItem, weight: 1}, {PropertyDamage.NemesisGenerationTest.NoGenNemesis, weight: 50}]
    end

    @impl true
    def command_sequence_projection, do: ModelState
  end

  defp all_commands(model, opts \\ []) do
    Generator.generate_sequence(model, Keyword.merge([max_commands: 10], opts))
    |> Enum.take(40)
    |> Enum.flat_map(&Sequence.to_list/1)
  end

  test "a weighted nemesis module produces nemesis instances during generation" do
    commands = all_commands(GenModel)

    nemeses = Enum.filter(commands, &match?(%GenNemesis{}, &1))

    assert nemeses != [], "expected the weighted nemesis to be generated via new!/2"
    # new!/2 overrides ran: severity is within the generated range.
    assert Enum.all?(nemeses, fn %GenNemesis{severity: s} -> s in 1..5 end)
  end

  test "precondition/1 filters a nemesis whose precondition is unmet" do
    commands = all_commands(UnmetModel)

    assert commands != []

    refute Enum.any?(commands, &match?(%UnmetNemesis{}, &1)),
           "a nemesis with an unmet precondition must not be selected"
  end

  test "a nemesis without new!/2 raises a clear error during generation" do
    assert_raise ArgumentError, ~r/new!\/2/, fn ->
      all_commands(NoGenModel)
    end
  end
end
