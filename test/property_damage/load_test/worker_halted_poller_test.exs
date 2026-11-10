defmodule PropertyDamage.LoadTest.WorkerHaltedPollerTest do
  # A session that halts while an `@eventually` window is open leaves the
  # window's result for a worker that no longer waits for it. The worker
  # drops that result without a log line.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest.{Metrics, Worker}

  defmodule Acted do
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
    def init, do: %{acts: 0}

    @impl true
    def apply(state, %Acted{}), do: %{state | acts: state.acts + 1}
    def apply(state, _other), do: state

    # Fails the second `Act`, so the session halts at its second root.
    @check every: Act
    def at_most_one_act(state, _command),
      do: state.acts < 2 or PropertyDamage.fail!("one act allowed")

    # Holds after the first root, so the window's result is sent to the
    # worker while the second root halts the session.
    @eventually after: Acted, timeout: {1, :seconds}, interval: {5, :milliseconds}
    def acts_settle(_state, %Acted{}), do: fn state -> state.acts >= 1 end
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
    def simulate(%Act{}, _state), do: [%Acted{}]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Act{}, _ctx, _runtime), do: {:ok, [%Acted{}]}
  end

  test "a poller result that arrives after the session halted is not logged as unexpected" do
    {:ok, metrics} = Metrics.start_link()

    {:ok, worker} =
      Worker.start_link(
        worker_id: 1,
        seed: 7,
        model: Model,
        target: %PropertyDamage.Target{adapter: Adapter, config: %{}, name: "halted", index: 0},
        metrics: metrics,
        think_time_range: {0, 0},
        check_mode: :halt
      )

    log =
      capture_log(fn ->
        {:ok, _stats} = Worker.execute_sequence(worker)
        # The window's result reaches the worker after the session ended.
        Process.sleep(100)
        :sys.get_state(worker)
      end)

    Worker.stop(worker)
    Metrics.stop(metrics)

    mine = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, inspect(worker)))
    refute Enum.any?(mine, &String.contains?(&1, "poller_result"))
  end
end
