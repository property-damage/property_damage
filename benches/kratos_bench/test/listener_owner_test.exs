defmodule KratosBench.ListenerOwnerTest do
  @moduledoc """
  The mock's web_hook listener outlives every run of a campaign.

  `PropertyDamage.run/1` calls the adapter's `setup/1` once per run, in a
  process that exits when the run ends. If the listener were that process's
  child, it would shut down after each run while Kratos still holds connections
  to it, and the next run's registrations would wait on a listener that no longer
  accepts them. The bench application owns the listener instead, so every run
  reaches the same one.
  """

  use ExUnit.Case, async: false

  alias KratosBench.RegistrationMock.Hub

  @moduletag timeout: 600_000

  defmodule RecordingAdapter do
    @moduledoc false
    # Wraps the bench adapter and reports the listener pid each run's setup/1 left.
    use PropertyDamage.Adapter

    alias KratosBench.Adapter, as: Inner

    @impl true
    def setup(config) do
      {:ok, context} = Inner.setup(config)
      send(config.test_pid, {:listener, Hub.get().listener})
      {:ok, context}
    end

    @impl true
    def teardown(context), do: Inner.teardown(context)

    @impl true
    def execute(command, context, runtime), do: Inner.execute(command, context, runtime)
  end

  test "every run of a campaign reaches the same listener" do
    config = KratosBench.target_config(%{test_pid: self()})

    assert {:ok, _stats} =
             PropertyDamage.run(
               model: KratosBench.Model,
               targets: [{RecordingAdapter, config: config}],
               max_commands: 16,
               max_runs: 3,
               seed: 1,
               verbose: false
             )

    listeners =
      for _run <- 1..3 do
        assert_received {:listener, pid}
        pid
      end

    refute_received {:listener, _}

    assert [listener] = Enum.uniq(listeners)
    assert Process.alive?(listener)
  end
end
