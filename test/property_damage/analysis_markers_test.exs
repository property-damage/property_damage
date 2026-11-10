defmodule PropertyDamage.AnalysisMarkersTest do
  @moduledoc """
  `Analysis.isolate_trigger/2` validates each varied sequence against the
  model, so it must read the run's `external_markers:` the way the run did.

  In the fixture, `Ship` needs two orders. Each `Create` mints its order id
  through the marker `:__external__`. Read as a literal atom, both ids fold
  into one key, the varied sequence looks invalid, and no variation counts.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Analysis

  @marker :__external__

  defmodule Created do
    defstruct id: :__external__, name: nil
  end

  defmodule Shipped do
    defstruct [:qty]
  end

  defmodule Create do
    use PropertyDamage.Command
    defstruct [:name]

    @impl true
    def generator(overrides \\ %{}) do
      %{name: StreamData.member_of(["alice", "bob"])}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Ship do
    use PropertyDamage.Command
    defstruct [:qty]

    @impl true
    def generator(overrides \\ %{}) do
      %{qty: StreamData.integer(3..9)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Orders do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{orders: %{}, shipped: 0}

    @impl true
    def apply(state, %Created{} = event), do: put_in(state, [:orders, event.id], event.name)
    def apply(state, %Shipped{qty: qty}), do: %{state | shipped: qty}
    def apply(state, _), do: state

    @check every: Shipped
    def shipment_is_small(state, _event), do: state.shipped <= 2
  end

  defmodule Model do
    use PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def commands do
      [
        {Create, weight: 1},
        {Ship, weight: 2, when: fn state -> map_size(state.orders) >= 2 end}
      ]
    end

    @impl true
    def command_sequence_projection, do: Orders
    @impl true
    def check_projections, do: [Orders]
    @impl true
    def simulator, do: __MODULE__

    @impl true
    def simulate(%Create{name: name}, _state), do: [%Created{name: name}]
    def simulate(%Ship{qty: qty}, _state), do: [%Shipped{qty: qty}]
    def simulate(_, _), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def execute(%Create{name: name}, _ctx, _runtime) do
      {:ok, [%Created{id: "ord_#{System.unique_integer([:positive])}", name: name}]}
    end

    def execute(%Ship{qty: qty}, _ctx, _runtime), do: {:ok, [%Shipped{qty: qty}]}

    @impl true
    def teardown(_ctx), do: :ok
  end

  setup do
    {:error, report} =
      PropertyDamage.run(
        model: Model,
        targets: [{Adapter, config: %{}}],
        external_markers: [@marker],
        seed: 1,
        max_runs: 50,
        max_commands: 8,
        verbose: false,
        replay_dir: false
      )

    %{report: report}
  end

  test "control: the report records the run's markers", %{report: report} do
    assert report.external_markers == [@marker]
  end

  test "lists the quantities that pass when the sequence is valid under the run's markers", %{
    report: report
  } do
    assert {:ok, %{changes: changes}} = Analysis.isolate_trigger(report)

    assert changes |> Enum.map(& &1.fixed) |> Enum.sort() |> Enum.filter(&(&1 <= 2)) != []
  end
end
