defmodule PropertyDamage.MockEventsBoundaryTest do
  @moduledoc """
  A mock event pushed after a command's own mock flush (here by a check that
  runs after the step folded its events) reaches the boundary state through
  the boundary drain (`Stepping.drain/2`), attributed to the command that
  last ran, and the final result through finalization.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, MockServiceRegistry, Sequence, Variant}
  alias PropertyDamage.Test.Lockstep.{Ledger, Noted, Stepped}
  alias PropertyDamage.Test.VariantSupport

  defmodule Mock do
    use PropertyDamage.MockServiceAdapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def init_state, do: %{}

    @impl true
    def on_command(_command, state), do: state

    @impl true
    def handle_request(_request, _state), do: {:ok, %{}}
  end

  defmodule Cmd do
    use PropertyDamage.Command
    # `coord` is an Agent the adapter fills with the run's mock registry.
    defstruct [:coord, :value]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{coord: nil, value: 0})
  end

  defmodule Pusher do
    use PropertyDamage.Model.Projection
    alias PropertyDamage.MockServiceRegistry

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    # Runs after the step flushed its mock events: stands in for a system
    # that calls the mock after the command returned.
    @check every: Cmd
    def push_late(_state, %Cmd{coord: coord, value: v}) do
      registry = Agent.get(coord, & &1)
      :ok = MockServiceRegistry.push_event(registry, Mock, %Noted{value: {:late_mock, v}})
    end
  end

  defmodule Model do
    use PropertyDamage.Model

    @impl true
    def commands, do: [Cmd]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [Pusher]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Cmd{coord: coord, value: v}, _ctx, runtime) do
      Agent.update(coord, fn _ -> runtime.mock_registry end)
      {:ok, [%Stepped{value: v}]}
    end
  end

  defp mock_entries(log),
    do: for(%{source: :mock, command_index: i, event: %{value: v}} <- log, do: {i, v})

  test "a mock event pushed before a boundary is in the boundary state and the final result" do
    {:ok, coord} = Agent.start_link(fn -> nil end)
    commands = [%Cmd{coord: coord, value: 1}, %Cmd{coord: coord, value: 2}]
    [target] = VariantSupport.targets!([{Adapter, name: "a", mocks: [{Mock, %{}}]}])
    {:ok, pid} = Variant.start(VariantSupport.variant_opts(target, Model, commands))
    :ok = Variant.setup(pid)

    assert {:ok, [{0, _}]} = Variant.advance_to(pid, 0)
    boundary = Variant.snapshot(pid)
    assert mock_entries(boundary.event_log) == [{0, {:late_mock, 1}}]
    assert boundary.projections[Ledger].noted == [{:late_mock, 1}]
    assert MockServiceRegistry.flush_events(boundary.mock_registry) == []

    assert {:ok, [{1, _}]} = Variant.advance_to(pid, 1)
    result = Variant.finish(pid)
    Variant.stop(pid)

    assert Enum.sort(mock_entries(result.event_log)) == [
             {0, {:late_mock, 1}},
             {1, {:late_mock, 2}}
           ]
  end

  test "a mock event pushed after the last command's flush is in the linear engine's result" do
    {:ok, coord} = Agent.start_link(fn -> nil end)
    {:ok, registry} = MockServiceRegistry.start_link([])
    :ok = MockServiceRegistry.register(registry, Mock)

    {:ok, result} =
      Executor.run(Sequence.linear([%Cmd{coord: coord, value: 1}]), Model, Adapter,
        mock_registry: registry
      )

    assert mock_entries(result.event_log) == [{0, {:late_mock, 1}}]
    assert result.projections[Ledger].noted == [{:late_mock, 1}]
  end
end
