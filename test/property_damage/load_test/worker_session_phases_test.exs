defmodule PropertyDamage.LoadTest.WorkerSessionPhasesTest do
  # A worker runs a model's startup checks, setup commands, teardown
  # commands and `@eventually` checks.
  # The projection checks log to a named agent because they run in the
  # worker's process.
  use ExUnit.Case, async: false

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest.{Metrics, Worker}
  alias PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log

  defmodule Seeded do
    defstruct []
  end

  defmodule Acted do
    defstruct []
  end

  defmodule Seed do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Act do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Cleanup do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule World do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{acts: 0}

    @impl true
    def apply(state, %Acted{}), do: %{state | acts: state.acts + 1}
    def apply(state, _other), do: state

    @check at: :startup
    def startup_ran(_state, _phase) do
      Agent.update(PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log, &[:startup | &1])
      :ok
    end

    # Fails every Act once the test has asked for failures.
    @check every: Act
    def acts_allowed(_state, _command) do
      log = PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log

      :fail_checks in Agent.get(log, & &1) and
        PropertyDamage.fail!("acts are not allowed")

      true
    end

    @eventually after: Acted, timeout: {1, :seconds}, interval: {5, :milliseconds}
    def acts_settle(_state, %Acted{}) do
      Agent.update(PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log, &[:eventually | &1])
      fn state -> state.acts >= 1 end
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Act]

    @impl true
    def setup_each, do: [Seed]

    @impl true
    def teardown_each, do: [Cleanup]

    @impl true
    def command_sequence_projection, do: World

    @impl true
    def check_projections, do: [World]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Act{}, _state), do: [%Acted{}]
    def simulate(%Seed{}, _state), do: [%Seeded{}]
    def simulate(_command, _state), do: []
  end

  defmodule Adapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Seed{}, _ctx, _runtime), do: log(Seed, [%Seeded{}])
    def execute(%Act{}, _ctx, _runtime), do: log(Act, [%Acted{}])
    def execute(%Cleanup{}, _ctx, _runtime), do: log(Cleanup, [])

    defp log(command, events) do
      Agent.update(PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log, &[command | &1])
      {:ok, events}
    end
  end

  setup do
    start_supervised!(%{
      id: :log,
      start:
        {Agent, :start_link,
         [fn -> [] end, [name: PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log]]}
    })

    :ok
  end

  defp run_session(check_mode \\ :record) do
    {:ok, metrics} = Metrics.start_link()

    {:ok, worker} =
      Worker.start_link(
        worker_id: 1,
        seed: 7,
        model: Model,
        target: %PropertyDamage.Target{adapter: Adapter, config: %{}, name: "phases", index: 0},
        metrics: metrics,
        check_mode: check_mode
      )

    {:ok, result} = Worker.execute_sequence(worker)
    Worker.stop(worker)
    Metrics.stop(metrics)
    {result, Agent.get(PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log, &Enum.reverse/1)}
  end

  test "a worker runs the startup check, setup, roots, eventual check and teardown" do
    {result, log} = run_session()

    assert result.commands_run >= 1
    assert result.check_failures == 0
    assert result.errors == 0

    assert [:startup, Seed | rest] = log
    assert Act in rest
    assert :eventually in rest
    assert List.last(log) == Cleanup
  end

  test "a worker counts each failed check in :record mode and the first in :halt mode" do
    Agent.update(Log, &[:fail_checks | &1])

    {recorded, _log} = run_session(:record)
    assert recorded.check_failures == recorded.commands_run

    {halted, _log} = run_session(:halt)
    assert halted.check_failures == 1
    assert halted.commands_run == 1
  end
end
