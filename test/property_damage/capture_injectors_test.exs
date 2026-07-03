defmodule PropertyDamage.CaptureInjectorsTest do
  @moduledoc """
  DR-035/DR-033: `RunTrace.capture/1` sets up injector adapters around the run,
  so injector (async, command-unattributed) events appear in the captured trace.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{EventQueue, RunTrace}

  defmodule Injected, do: defstruct([:tag])

  defmodule Cmd do
    @behaviour PropertyDamage.Command
    defstruct [:n]
    @impl true
    def generator(_), do: StreamData.constant(%{n: 1})
  end

  defmodule Proj do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: Proj
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_c, _s), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(c), do: {:ok, c}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def execute(%Cmd{}, _ctx, _rt), do: {:ok, []}
  end

  # An injector that enqueues one async event on setup, using the event queue it
  # is handed. During the run this drains into the log with no command index.
  defmodule Injector do
    use PropertyDamage.Adapter.Injector

    alias PropertyDamage.CaptureInjectorsTest.Injected

    @emits [Injected]

    @impl true
    def setup(%{event_queue: queue}) do
      EventQueue.push(queue, __MODULE__, %Injected{tag: :hello})
      {:ok, %{event_queue: queue}}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def to_event(_payload), do: :skip
  end

  test "captured trace includes injector events (async, command-unattributed)" do
    trace =
      RunTrace.capture(
        model: Model,
        adapter: Adapter,
        seed: 1,
        max_commands: 3,
        injector_adapters: [Injector]
      )

    injected = RunTrace.async_entries(trace)

    assert Enum.any?(injected, &match?(%{event: %Injected{tag: :hello}}, &1)),
           "expected the injector's async event in the captured trace"
  end

  test "without injector_adapters the trace has no injected events" do
    trace = RunTrace.capture(model: Model, adapter: Adapter, seed: 1, max_commands: 3)
    refute Enum.any?(RunTrace.async_entries(trace), &match?(%{event: %Injected{}}, &1))
  end
end
