defmodule PropertyDamage.ExternalMarkersRunTest do
  @moduledoc """
  The `external_markers:` run option reaches the generator and the executor, so
  an atom marker a domain library puts in an event struct is minted by the SUT
  and resolved into later commands.
  """
  use ExUnit.Case, async: false

  defmodule Created do
    defstruct id: :__external__, name: nil
  end

  defmodule Shipped do
    defstruct [:order_id]
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
    defstruct [:order_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{order_id: StreamData.constant(nil)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Projection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{orders: %{}}

    @impl true
    def apply(state, %Created{} = event), do: put_in(state, [:orders, event.id], event.name)
    def apply(state, _), do: state
  end

  defmodule Model do
    use PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl true
    def commands do
      [
        {Create, weight: 1},
        {Ship,
         weight: 2,
         when: fn state -> map_size(state.orders) > 0 end,
         overrides: fn state -> %{order_id: StreamData.member_of(Map.keys(state.orders))} end}
      ]
    end

    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def check_projections, do: []
    @impl true
    def simulator, do: __MODULE__

    @impl true
    def simulate(%Create{name: name}, _state), do: [%Created{name: name}]
    def simulate(%Ship{order_id: id}, _state), do: [%Shipped{order_id: id}]
    def simulate(_, _), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, %{log: config.log}}

    @impl true
    def execute(%Create{name: name}, ctx, _runtime) do
      id = "ord_#{System.unique_integer([:positive])}"
      Agent.update(ctx.log, &[{:minted, id} | &1])
      {:ok, [%Created{id: id, name: name}]}
    end

    def execute(%Ship{order_id: id}, ctx, _runtime) do
      Agent.update(ctx.log, &[{:shipped, id} | &1])
      {:ok, [%Shipped{order_id: id}]}
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  defp run_logged(extra) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    result =
      PropertyDamage.run(
        [
          model: Model,
          targets: [{Adapter, config: %{log: log}}],
          max_runs: 10,
          max_commands: 8,
          seed: 1,
          verbose: false
        ] ++ extra
      )

    entries = Agent.get(log, & &1)
    Agent.stop(log)
    {result, for({:minted, id} <- entries, do: id), for({:shipped, id} <- entries, do: id)}
  end

  test "run/1 resolves an atom marker into the id the SUT minted" do
    {result, minted, shipped} = run_logged(external_markers: [:__external__])

    assert match?({:ok, _}, result)
    assert shipped != []
    assert Enum.all?(shipped, &(&1 in minted))
    refute :__external__ in shipped
  end

  test "without the option the literal marker reaches the command" do
    {_result, _minted, shipped} = run_logged([])

    assert :__external__ in shipped
  end
end
