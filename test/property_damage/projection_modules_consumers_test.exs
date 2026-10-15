defmodule PropertyDamage.ProjectionModulesConsumersTest do
  @moduledoc """
  A projection listed only in `check_projections/0` is seen by every consumer
  of a model's projections: the engine initializes and folds it, runs its
  synchronous checks and opens its `@eventually` windows, and a trace's
  derived state holds it.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{EventQueue, Executor, Failure, RunTrace, Sequence}

  defmodule Pinged, do: defstruct([])

  defmodule Ping do
    @behaviour PropertyDamage.Command
    defstruct fail: false, await: false

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{fail: false, await: false})
  end

  defmodule Sequenced do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _item), do: state
  end

  defmodule OnlyChecks do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{pings: 0}

    @impl true
    def apply(state, %Pinged{}), do: %{state | pings: state.pings + 1}
    def apply(state, _item), do: state

    @check every: Ping
    def ping_ok(_state, %Ping{fail: fail}) do
      if fail, do: PropertyDamage.fail!("ping failed")
    end

    @eventually after: Pinged, timeout: {30, :milliseconds}, interval: {5, :milliseconds}
    def answered(_state, %Pinged{}) do
      fn s -> s.pings < 0 end
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Ping]

    @impl true
    def command_sequence_projection, do: Sequenced

    @impl true
    def check_projections, do: [OnlyChecks]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Ping{await: true}, _ctx, _runtime), do: {:ok, [%Pinged{}]}
    def execute(%Ping{}, _ctx, _runtime), do: {:ok, []}
  end

  defp run(commands) do
    {:ok, queue} = EventQueue.start_link()
    {:ok, result} = Executor.run(Sequence.linear(commands), Model, Adapter, event_queue: queue)
    result
  end

  test "the engine initializes it and folds into it" do
    assert %{pings: 0} = run([%Ping{}]).projections[OnlyChecks]
  end

  test "the engine runs its synchronous checks" do
    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :ping_ok}} =
             run([%Ping{fail: true}]).failure_reason
  end

  test "the engine opens its @eventually windows" do
    assert %Failure{type: %Failure.Check{kind: :poll_timeout, name: :answered}} =
             run([%Ping{await: true}]).failure_reason
  end

  test "a trace's derived state holds it" do
    trace = RunTrace.capture(model: Model, targets: [{Adapter, []}], seed: 1, max_commands: 2)
    assert %{pings: 0} = RunTrace.state_at(trace, 0)[OnlyChecks]
  end
end
