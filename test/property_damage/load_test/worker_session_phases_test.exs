defmodule PropertyDamage.LoadTest.WorkerSessionPhasesTest do
  # A worker runs a model's startup checks, setup commands, teardown
  # commands and `@eventually` checks.
  # The projection checks log to a named agent because they run in the
  # worker's process.
  use ExUnit.Case, async: false

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest
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

      unsettled? =
        :never_settle in Agent.get(PropertyDamage.LoadTest.WorkerSessionPhasesTest.Log, & &1)

      fn state -> not unsettled? and state.acts >= 1 end
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

  test "a worker counts an eventual check that never settles as a check failure" do
    Agent.update(Log, &[:never_settle | &1])

    {result, log} = run_session()

    assert :eventually in log
    assert result.check_failures >= 1
    assert result.errors == 0
  end

  test "a worker counts each failed check in :record mode and the first in :halt mode" do
    Agent.update(Log, &[:fail_checks | &1])

    {recorded, _log} = run_session(:record)
    assert recorded.check_failures == recorded.commands_run

    {halted, _log} = run_session(:halt)
    assert halted.check_failures == 1
    assert halted.commands_run == 1
  end

  defp stutter_all, do: [probability: 1.0, max_repeats: 1, delay_ms: 0]

  defp run_load(opts) do
    LoadTest.run(
      [
        model: Model,
        targets: [Adapter],
        arrival_rate: 20,
        duration: {300, :milliseconds},
        check_mode: :record
      ] ++ opts
    )
  end

  test "a load run counts the commands, checks and retries of every phase" do
    {:ok, report} = run_load(stutter: stutter_all())

    counts = report.metrics.phase_counts
    assert counts.setup_commands > 0
    assert counts.teardown_commands > 0
    assert counts.eventual_checks > 0
    assert counts.stutter_retries > 0
    assert report.metrics.check_failures == 0

    assert LoadTest.format(report, :terminal) =~ "Stutter Retries:"
    assert LoadTest.format(report, :markdown) =~ "**Stutter Retries:** #{counts.stutter_retries}"
    assert LoadTest.summary(report) =~ "#{counts.stutter_retries} stutter retries"
  end

  test "a load run without stutter counts no retries" do
    {:ok, report} = run_load([])

    assert report.metrics.phase_counts.stutter_retries == 0
    assert report.metrics.phase_counts.setup_commands > 0
  end

  test "a load run emits engine command telemetry" do
    handler = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:property_damage, :command, :stop],
      fn _event, _measurements, meta, _config -> send(test_pid, {:command, meta.phase}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, _report} = run_load([])

    assert_received {:command, :root}
    assert_received {:command, :setup}
    assert_received {:command, :teardown}
  end

  test "a load run rejects an invalid stutter option" do
    assert_raise NimbleOptions.ValidationError, fn ->
      run_load(stutter: [probability: "always"])
    end
  end
end
