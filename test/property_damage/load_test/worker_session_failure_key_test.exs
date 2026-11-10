defmodule PropertyDamage.LoadTest.WorkerSessionFailureKeyTest do
  # A check failure that belongs to the whole session (a startup check, an
  # `@eventually` check that never settles) names no command. The load metrics
  # record it under the `:session` key, not under nil.
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

  defmodule BrokenStartup do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check at: :startup
    def startup_broken(_state, _phase), do: PropertyDamage.fail!("startup broken")
  end

  defmodule NeverSettles do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @eventually after: Done, timeout: {50, :milliseconds}, interval: {5, :milliseconds}
    def never_settles(_state, %Done{}), do: fn _state -> false end
  end

  defmodule StartupModel do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Act]

    @impl true
    def command_sequence_projection, do: BrokenStartup

    @impl true
    def check_projections, do: [BrokenStartup]

    @impl true
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Act{}, _state), do: [%Done{}]
  end

  defmodule EventualModel do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Act]

    @impl true
    def command_sequence_projection, do: NeverSettles

    @impl true
    def check_projections, do: [NeverSettles]

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

  defp recorded_failures(model, check_mode) do
    {:ok, metrics} = Metrics.start_link()

    {:ok, worker} =
      Worker.start_link(
        worker_id: 1,
        seed: 7,
        model: model,
        target: %PropertyDamage.Target{adapter: Adapter, config: %{}, name: "key", index: 0},
        metrics: metrics,
        think_time_range: {0, 0},
        check_mode: check_mode
      )

    {:ok, stats} = Worker.execute_sequence(worker)
    Worker.stop(worker)
    snapshot = Metrics.snapshot(metrics)
    Metrics.stop(metrics)

    assert stats.check_failures >= 1
    snapshot.recent_check_failures
  end

  test "a failed startup check is recorded under the session key" do
    failures = recorded_failures(StartupModel, :record)

    assert failures != []
    assert Enum.all?(failures, &(&1.command_module == :session and &1.module == :session))
  end

  test "an eventual check that never settles, found at the end of a halting session, is recorded under the session key" do
    failures = recorded_failures(EventualModel, :halt)

    assert failures != []
    assert Enum.all?(failures, &(&1.command_module == :session and &1.module == :session))
  end
end
