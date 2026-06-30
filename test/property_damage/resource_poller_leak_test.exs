defmodule PropertyDamage.ResourcePollerLeakTest do
  # async: false — the failing run logs a failure report; keep it isolated.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule PollerCmd do
    @behaviour PropertyDamage.Command
    defstruct [:val]

    @impl true
    def generator(overrides \\ %{}) do
      %{val: StreamData.constant(1)}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule PollerProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule PollerModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [PollerCmd]
    @impl true
    def command_sequence_projection, do: PollerProjection
  end

  # Adapter that starts a resource poller during execute and then returns an
  # error. The poller is given a long interval/timeout so it cannot self-
  # terminate within the test; the only way it dies is if the run stops it.
  defmodule FailingPollerAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%PollerCmd{}, ctx, runtime) do
      poller =
        runtime.start_poller.(
          poll_fn: fn -> :polling end,
          handler: fn _ -> :continue end,
          interval_ms: 60_000,
          timeout_ms: 60_000
        )

      send(ctx.test_pid, {:poller, poller})
      {:error, :boom}
    end
  end

  test "a resource poller started before an adapter error is stopped, not leaked" do
    capture_log(fn ->
      result =
        PropertyDamage.run(
          model: PollerModel,
          adapter: FailingPollerAdapter,
          adapter_config: %{test_pid: self()},
          max_runs: 1,
          max_commands: 3,
          shrink: false,
          validate: false
        )

      assert {:error, _report} = result
    end)

    assert_received {:poller, poller}
    # Give the stop a beat to take effect.
    Process.sleep(20)

    refute Process.alive?(poller.pid),
           "resource poller leaked on the adapter-error path (not stopped at run end)"
  end
end
