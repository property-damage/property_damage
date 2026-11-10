defmodule PropertyDamage.LoadTest.WorkerFailedStepTest do
  # Characterization of what a load worker does after a step fails: it keeps
  # stepping the same session from the failed state. The Variant stops its
  # session at the first step failure. Each test shows the worker's session
  # running more commands than the one that failed.
  use ExUnit.Case, async: true

  alias PropertyDamage.Generator
  alias PropertyDamage.LoadTest.{Metrics, Worker}

  defmodule Created do
    defstruct [:label]
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct [:label]

    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{label: StreamData.constant("x")}, overrides)
      )
    end
  end

  defmodule Waits do
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 20, interval_ms: 5, backoff: :linear}

    defstruct []

    @impl true
    def generator(overrides \\ %{}),
      do: StreamData.fixed_map(Generator.merge_overrides(%{}, overrides))
  end

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _event), do: state
  end

  defmodule Done do
    defstruct []
  end

  defmodule PlainModel do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Create]
    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{label: l}, _state), do: [%Created{label: l}]
  end

  defmodule WaitsModel do
    @behaviour PropertyDamage.Model.Simulator
    use PropertyDamage.Model

    @impl true
    def commands, do: [Waits]
    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%Waits{}, _state), do: [%Done{}]
  end

  # The adapter's answer comes from the config `:mode`.
  defmodule Adapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Create{}, %{mode: :error}, _runtime), do: {:error, :nope}
    def execute(%Create{}, %{mode: :raise}, _runtime), do: raise("adapter boom")
    def execute(%Waits{}, _ctx, _runtime), do: {:retry, :not_ready}
  end

  defp session(model, mode) do
    {:ok, metrics} = Metrics.start_link()

    {:ok, worker} =
      Worker.start_link(
        worker_id: 1,
        seed: 7,
        model: model,
        target: %PropertyDamage.Target{
          adapter: Adapter,
          config: %{mode: mode},
          name: "failed",
          index: 0
        },
        metrics: metrics,
        think_time_range: {0, 0},
        check_mode: :record
      )

    {:ok, stats} = Worker.execute_sequence(worker)
    Worker.stop(worker)
    Metrics.stop(metrics)
    stats
  end

  test "a session goes on after an adapter error" do
    stats = session(PlainModel, :error)

    assert stats.commands_run > 1
    assert stats.errors == stats.commands_run
  end

  test "a session goes on after an adapter raise" do
    stats = session(PlainModel, :raise)

    assert stats.commands_run > 1
    assert stats.errors == stats.commands_run
  end

  test "a session goes on after a settle timeout" do
    stats = session(WaitsModel, :retry)

    assert stats.commands_run > 1
    assert stats.errors == stats.commands_run
  end
end
