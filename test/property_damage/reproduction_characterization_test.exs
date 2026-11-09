defmodule PropertyDamage.ReproductionCharacterizationTest do
  @moduledoc """
  Pins three behaviors of the failure path that no other test reaches: the
  replay status when no artifact is written, the status when the write fails,
  and the composition of `on_failure:` with `regression:`.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport

  defmodule Cmd do
    use PropertyDamage.Command
    defstruct [:n]
    @impl true
    def generator(_overrides), do: StreamData.fixed_map(%{n: StreamData.integer(0..10)})
  end

  defmodule State do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
  end

  defmodule AlwaysFail do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state

    @check every: 1
    def assert_never(_state, _cmd_or_event), do: PropertyDamage.fail!("always fails")
  end

  defmodule Model do
    use PropertyDamage.Model
    def commands, do: [Cmd]
    def command_sequence_projection, do: State
    def check_projections, do: [AlwaysFail]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    def setup(config), do: {:ok, config}
    def teardown(_context), do: :ok
    def execute(_command, _context, _runtime), do: {:ok, []}
  end

  defp failing_run(extra) do
    PropertyDamage.run(
      [
        model: Model,
        targets: [Adapter],
        max_runs: 1,
        max_commands: 3,
        seed: 12_345,
        validate: false
      ] ++ extra
    )
  end

  test "replay_dir: false writes no artifact and says so" do
    assert {:error, %FailureReport{} = report} = failing_run(replay_dir: false)
    assert report.replay_status == :disabled
    assert report.replay_path == nil
  end

  @tag :tmp_dir
  test "a replay_dir that cannot be written costs the artifact, not the report", %{
    tmp_dir: tmp_dir
  } do
    blocker = Path.join(tmp_dir, "not_a_directory")
    File.write!(blocker, "")

    assert {:error, %FailureReport{} = report} = failing_run(replay_dir: blocker)
    assert {:write_failed, _reason} = report.replay_status
    assert report.replay_path == nil
  end

  @tag :tmp_dir
  test "on_failure and regression both receive the report", %{tmp_dir: tmp_dir} do
    test_pid = self()
    failures_dir = Path.join(tmp_dir, "failures")

    assert {:error, %FailureReport{}} =
             failing_run(
               replay_dir: false,
               on_failure: fn report -> send(test_pid, {:on_failure, report}) end,
               regression: [save_failures: failures_dir]
             )

    assert_received {:on_failure, %FailureReport{}}
    assert File.ls!(failures_dir) != []
  end
end
