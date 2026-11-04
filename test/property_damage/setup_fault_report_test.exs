defmodule PropertyDamage.SetupFaultReportTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport}

  defmodule Bumped do
    defstruct []
  end

  defmodule Bump do
    @behaviour PropertyDamage.Command
    defstruct []
    def generator(_ \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    def setup(config), do: {:ok, config}
    def teardown(_), do: :ok
    def execute(%Bump{}, _, _), do: {:ok, [%Bumped{}]}
  end

  defmodule DownAdapter do
    use PropertyDamage.Adapter
    def setup(_config), do: {:error, :down}
    def teardown(_), do: :ok
    def execute(%Bump{}, _, _), do: {:ok, [%Bumped{}]}
  end

  defmodule ExitProj do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
    @check at: :startup
    def startup_probe(_state, _phase), do: exit(:boom_exit)
  end

  defmodule ThrowProj do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
    @check at: :startup
    def startup_probe(_state, _phase), do: throw(:boom_throw)
  end

  defmodule DuringRunThrowProj do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
    @check every: 1
    def after_each(_state, _trigger), do: throw(:boom_during_run)
  end

  defmodule OldShapeProj do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
    def __checks__, do: [%{name: :old_shape, trigger: :always}]
  end

  defmodule RecordingAdapter do
    use PropertyDamage.Adapter
    def setup(config), do: {:ok, config}
    def teardown(%{test_pid: pid}), do: send(pid, :adapter_torn_down)
    def execute(%Bump{}, _, _), do: {:ok, [%Bumped{}]}
  end

  defmodule KillProj do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
    @check at: :startup
    def startup_probe(_state, _phase), do: Process.exit(self(), :kill)
  end

  defmodule KillModel do
    use PropertyDamage.Model
    def commands, do: [Bump]
    def command_sequence_projection, do: KillProj
  end

  defmodule ExitModel do
    use PropertyDamage.Model
    def commands, do: [Bump]
    def command_sequence_projection, do: ExitProj
  end

  defmodule ThrowModel do
    use PropertyDamage.Model
    def commands, do: [Bump]
    def command_sequence_projection, do: ThrowProj
  end

  defmodule DuringRunModel do
    use PropertyDamage.Model
    def commands, do: [Bump]
    def command_sequence_projection, do: DuringRunThrowProj
  end

  defmodule OldShapeModel do
    use PropertyDamage.Model
    def commands, do: [Bump]
    def command_sequence_projection, do: OldShapeProj
  end

  defp run(model, adapter \\ Adapter) do
    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: model,
               targets: [adapter],
               max_runs: 1,
               max_commands: 2,
               shrink: false
             )

    report
  end

  test "a startup check that exits is that check's failure" do
    report = run(ExitModel)

    assert report.kind == :check_failed
    assert %Failure{type: %Failure.Check{name: :startup_probe}} = report.failure_reason
    message = FailureReport.failure_message(report)
    assert message =~ "boom_exit"
    refute message =~ "Adapter setup failed"
  end

  test "a startup check that throws is that check's failure" do
    report = run(ThrowModel)

    assert report.kind == :check_failed
    assert %Failure{type: %Failure.Check{name: :startup_probe}} = report.failure_reason
    message = FailureReport.failure_message(report)
    assert message =~ "boom_throw"
    refute message =~ "Adapter setup failed"
  end

  test "a during-run check that throws is that check's failure" do
    report = run(DuringRunModel)

    assert report.kind == :check_failed
    assert %Failure{type: %Failure.Check{name: :after_each}} = report.failure_reason
    assert FailureReport.failure_message(report) =~ "boom_during_run"
  end

  test "a malformed __checks__/0 entry is reported against the projection, not the adapter" do
    report = run(OldShapeModel)

    assert %Failure{type: %Failure.Setup{cause: cause}} = report.failure_reason
    assert cause == :model
    message = FailureReport.failure_message(report)
    assert message =~ inspect(OldShapeProj)
    assert message =~ "old_shape"
    refute message =~ "Adapter setup failed"
  end

  test "control: an adapter whose setup/1 fails is still an adapter setup failure" do
    report = run(ExitModel, DownAdapter)

    assert report.kind == :setup_failed
    assert %Failure{type: %Failure.Setup{cause: :adapter_setup}} = report.failure_reason
    assert FailureReport.failure_message(report) =~ "Adapter setup failed"
  end

  test "the adapter's teardown/1 runs after model code faults while the variant comes up" do
    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: OldShapeModel,
               targets: [{RecordingAdapter, config: %{test_pid: self()}}],
               max_runs: 1,
               max_commands: 2,
               shrink: false
             )

    assert %Failure{type: %Failure.Setup{cause: :model}} = report.failure_reason
    assert_received :adapter_torn_down
  end

  test "a variant process that dies while it comes up is reported as a variant crash" do
    report = run(KillModel)

    assert report.kind == :setup_failed
    assert %Failure{type: %Failure.Setup{cause: :variant}} = report.failure_reason
    message = FailureReport.failure_message(report)
    assert message =~ "variant"
    refute message =~ "Adapter setup failed"
  end
end
