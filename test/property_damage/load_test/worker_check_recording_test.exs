defmodule PropertyDamage.LoadTest.WorkerCheckRecordingTest do
  # A load worker evaluates a projection's step checks through
  # `Projection.Checks.step_checks/4`, which stops at the first failing check.
  # A step on which two checks of one projection fail therefore records one
  # failure for that projection, not two.
  use ExUnit.Case, async: true

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest.{Metrics, Worker}

  defmodule Done do
    defstruct []
  end

  defmodule Act do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Rules do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: Act
    def first_rule(_state, _command), do: PropertyDamage.fail!("first rule broken")

    @check every: Act
    def second_rule(_state, _command), do: PropertyDamage.fail!("second rule broken")
  end

  defmodule Model do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Act]

    @impl true
    def command_sequence_projection, do: Rules

    @impl true
    def check_projections, do: [Rules]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Act{}, _state), do: [%Done{}]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Act{}, _ctx, _runtime), do: {:ok, [%Done{}]}
  end

  test "a step with two failing checks on one projection records the first failing check only" do
    {:ok, metrics} = Metrics.start_link()

    {:ok, worker} =
      Worker.start_link(
        worker_id: 1,
        seed: 7,
        model: Model,
        target: %PropertyDamage.Target{adapter: Adapter, config: %{}, name: "rules", index: 0},
        metrics: metrics,
        think_time_range: {0, 0},
        check_mode: :record
      )

    {:ok, stats} = Worker.execute_sequence(worker)
    Worker.stop(worker)

    # Let the metrics process fold the worker's casts before reading.
    snapshot = Metrics.snapshot(metrics)
    Metrics.stop(metrics)

    assert stats.commands_run >= 1
    assert stats.check_failures == stats.commands_run
    assert snapshot.check_failures == stats.commands_run

    names = Enum.map(snapshot.recent_check_failures, & &1.check_name)
    assert Enum.uniq(names) == [:first_rule]
  end
end
