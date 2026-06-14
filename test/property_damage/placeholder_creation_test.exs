defmodule PropertyDamage.PlaceholderCreationTest do
  @moduledoc """
  R3 cluster A: placeholders are created during simulation (DR-021).

  Before R3, nothing instantiated placeholders: the generator applied raw
  simulated events (carrying `%External{}` sentinels) straight into projection
  state, and `Sequence` had no registry to transport. These tests pin that the
  generator now mints a `%Placeholder{}` per external field, records it by
  structured position, and attaches the id-indexed registry to the sequence.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Generator, Placeholder, PlaceholderRegistry, Sequence}

  defmodule ItemCreated do
    import PropertyDamage, only: [external: 0]
    defstruct [:name, id: external()]
  end

  defmodule CreateItem do
    @behaviour PropertyDamage.Command
    defstruct [:name]

    @impl true
    def generator(overrides) do
      base = %{name: StreamData.constant("widget")}
      StreamData.fixed_map(Generator.merge_overrides(base, overrides))
    end
  end

  defmodule CreateProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{items: %{}}
    @impl true
    def apply(state, %CreateItem{}), do: state
    def apply(state, %ItemCreated{id: id, name: name}), do: put_in(state.items[id], name)
    def apply(state, _other), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl PropertyDamage.Model
    def commands, do: [CreateItem]
    @impl PropertyDamage.Model
    def command_sequence_projection, do: CreateProjection
    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%CreateItem{name: name}, _state), do: [%ItemCreated{name: name}]
    def simulate(_command, _state), do: []
  end

  # A model whose events declare no external() fields.
  defmodule PlainEvent do
    defstruct [:value]
  end

  defmodule PlainProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _item), do: state
  end

  defmodule PlainModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl PropertyDamage.Model
    def commands, do: [CreateItem]
    @impl PropertyDamage.Model
    def command_sequence_projection, do: PlainProjection
    @impl PropertyDamage.Model
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%CreateItem{name: name}, _state), do: [%PlainEvent{value: name}]
    def simulate(_command, _state), do: []
  end

  describe "creation during simulation" do
    test "attaches an id-indexed registry with one placeholder per external field" do
      seq =
        Model
        |> Generator.generate_sequence(max_commands: 5)
        |> Generator.generate_value(1234)

      assert %Sequence{registry: %PlaceholderRegistry{} = reg, branches: nil} = seq

      placeholders = PlaceholderRegistry.all(reg)
      refute placeholders == [], "expected placeholders to be minted, got none"
      assert length(placeholders) == length(seq.prefix)
    end

    test "minted placeholders are position-identified, unresolved, and shaped correctly" do
      seq =
        Model
        |> Generator.generate_sequence(max_commands: 5)
        |> Generator.generate_value(99)

      placeholders = PlaceholderRegistry.all(seq.registry)

      Enum.each(placeholders, fn p ->
        assert %Placeholder{} = p
        assert p.event_module == ItemCreated
        assert p.path == [:id]
        assert match?({:prefix, i} when is_integer(i), p.position)
        # New scheme uses `position`, not the legacy flat command_index.
        assert p.command_index == nil
        refute Placeholder.resolved?(p)
      end)

      # Positions cover the contiguous {:prefix, 0..n-1} range, one per command.
      positions = placeholders |> Enum.map(& &1.position) |> Enum.sort()
      expected = Enum.map(0..(length(seq.prefix) - 1), &{:prefix, &1})
      assert positions == expected
    end

    test "each placeholder is reachable via its producer position" do
      seq =
        Model
        |> Generator.generate_sequence(max_commands: 4)
        |> Generator.generate_value(7)

      reg = seq.registry

      Enum.each(PlaceholderRegistry.all(reg), fn p ->
        assert p.id in PlaceholderRegistry.ids_at_position(reg, p.position)
      end)
    end

    test "no registry is attached for a model without external fields" do
      seq =
        PlainModel
        |> Generator.generate_sequence(max_commands: 5)
        |> Generator.generate_value(1234)

      assert seq.registry == nil
    end
  end

  describe "consumer-routing affordance" do
    test "available_externals surfaces placeholders from projection state" do
      p = Placeholder.new_at(ItemCreated, [:id], {:prefix, 0}, 0)
      state = %{items: %{p => "widget"}}

      assert Generator.available_externals(state) == [p]
      assert Generator.available_externals(state, event_module: ItemCreated) == [p]
      assert Generator.available_externals(state, path: [:id]) == [p]
      assert Generator.available_externals(state, event_module: CreateItem) == []
      assert Generator.available_externals(state, path: [:other]) == []
    end

    test "external_from yields a matching placeholder, or nil when none match" do
      p = Placeholder.new_at(ItemCreated, [:id], {:prefix, 0}, 0)
      state = %{items: %{p => "widget"}}

      picked = Generator.external_from(state, path: [:id]) |> Enum.at(0)
      assert picked == p

      none = Generator.external_from(state, path: [:missing]) |> Enum.at(0)
      assert none == nil
    end
  end
end
