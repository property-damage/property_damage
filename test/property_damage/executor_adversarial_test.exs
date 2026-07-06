defmodule PropertyDamage.ExecutorAdversarialTest do
  @moduledoc """
  Adversarial fixtures: the executor must turn misbehaving adapters/projections
  into graceful failure reports, never crash the run. Several of these paths
  used to raise outside the per-command rescue (CaseClauseError on a malformed
  adapter return; a raising projection).
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Failure, Sequence}

  defmodule Cmd do
    use PropertyDamage.Command
    defstruct [:tag]
    @impl true
    def generator(_overrides), do: StreamData.constant(%{tag: :x})
  end

  defmodule Ev do
    defstruct [:tag]
  end

  defmodule NoopProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _item), do: state
  end

  defmodule RaisingProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(_state, %Ev{}), do: raise("projection boom")
    def apply(state, _item), do: state
  end

  defmodule ExitingProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(_state, %Ev{}), do: exit(:proj_boom)
    def apply(state, _item), do: state
  end

  defmodule ThrowingProjection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(_state, %Ev{}), do: throw(:proj_thrown)
    def apply(state, _item), do: state
  end

  defmodule NoopModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: NoopProjection
  end

  defmodule RaisingProjectionModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: RaisingProjection
  end

  defmodule ExitingProjectionModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: ExitingProjection
  end

  defmodule ThrowingProjectionModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: ThrowingProjection
  end

  # An adapter whose behaviour is dictated by the command tag carried in config.
  defmodule Adversary do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Cmd{}, %{behaviour: :raise}, _runtime), do: raise("adapter boom")
    def execute(%Cmd{}, %{behaviour: :exit}, _runtime), do: exit(:boom)
    def execute(%Cmd{}, %{behaviour: :throw}, _runtime), do: throw(:thrown_boom)
    def execute(%Cmd{}, %{behaviour: :malformed_atom}, _runtime), do: :garbage
    def execute(%Cmd{}, %{behaviour: :malformed_ok}, _runtime), do: {:ok, :not_a_list}
    def execute(%Cmd{}, %{behaviour: :sync_retry}, _runtime), do: {:retry, :not_ready}
    def execute(%Cmd{}, %{behaviour: :error}, _runtime), do: {:error, :nope}
    def execute(%Cmd{}, _ctx, _runtime), do: {:ok, [%Ev{tag: :x}]}

    @impl true
    def teardown(%{behaviour: :teardown_exit}), do: exit(:teardown_boom)
    def teardown(%{behaviour: :teardown_throw}), do: throw(:teardown_thrown)
    def teardown(_ctx), do: :ok
  end

  defp run(model, behaviour) do
    seq = Sequence.linear([%Cmd{tag: :x}])
    Executor.run(seq, model, Adversary, adapter_config: %{behaviour: behaviour})
  end

  test "a raising adapter becomes a graceful adapter_error, not a crash" do
    assert {:ok, result} = run(NoopModel, :raise)
    assert result.failed_at_index == 0

    assert match?(
             %Failure{
               type: %Failure.Execution{
                 kind: :adapter_error,
                 detail: %RuntimeError{message: "adapter boom"}
               }
             },
             result.failure_reason
           )
  end

  test "an adapter that exits becomes a graceful adapter_error, not a crash" do
    assert {:ok, result} = run(NoopModel, :exit)
    assert result.failed_at_index == 0

    assert %Failure{type: %Failure.Execution{kind: :adapter_error, detail: {:exit, :boom}}} =
             result.failure_reason
  end

  test "an adapter that throws becomes a graceful adapter_error, not a crash" do
    assert {:ok, result} = run(NoopModel, :throw)
    assert result.failed_at_index == 0

    assert %Failure{
             type: %Failure.Execution{kind: :adapter_error, detail: {:throw, :thrown_boom}}
           } = result.failure_reason
  end

  test "a malformed atom return is reported, not a CaseClauseError" do
    assert {:ok, result} = run(NoopModel, :malformed_atom)
    assert result.failed_at_index == 0

    assert %Failure{type: %Failure.Execution{kind: :malformed_adapter_return, detail: :garbage}} =
             result.failure_reason
  end

  test "an {:ok, non-list} return is reported as malformed" do
    assert {:ok, result} = run(NoopModel, :malformed_ok)
    assert result.failed_at_index == 0

    assert %Failure{
             type: %Failure.Execution{kind: :malformed_adapter_return, detail: {:ok, :not_a_list}}
           } = result.failure_reason
  end

  test "a sync command returning {:retry, _} is reported as a clear contract error, not a CaseClauseError" do
    assert {:ok, result} = run(NoopModel, :sync_retry)
    assert result.failed_at_index == 0
    # {:retry, _} is the probe/async settle protocol; a :sync command must not
    # return it. Surface a specific contract error, not generic :malformed.
    assert %Failure{type: %Failure.Execution{kind: :retry_from_sync_command, detail: details}} =
             result.failure_reason

    assert details.reason == :not_ready
  end

  test "a plain {:error, reason} is reported as adapter_error" do
    assert {:ok, result} = run(NoopModel, :error)
    assert result.failed_at_index == 0

    assert %Failure{type: %Failure.Execution{kind: :adapter_error, detail: :nope}} =
             result.failure_reason
  end

  test "a raising projection becomes a projection_violation, not a crash" do
    assert {:ok, result} = run(RaisingProjectionModel, :ok)
    assert result.failed_at_index == 0

    assert match?(
             %Failure{
               type: %Failure.Assertion{kind: :projection_violation, name: RaisingProjection}
             },
             result.failure_reason
           )
  end

  test "a projection that exits becomes a projection_violation, not a crash" do
    assert {:ok, result} = run(ExitingProjectionModel, :ok)
    assert result.failed_at_index == 0

    assert match?(
             %Failure{
               type: %Failure.Assertion{kind: :projection_violation, name: ExitingProjection}
             },
             result.failure_reason
           )
  end

  test "a projection that throws becomes a projection_violation, not a crash" do
    assert {:ok, result} = run(ThrowingProjectionModel, :ok)
    assert result.failed_at_index == 0

    assert match?(
             %Failure{
               type: %Failure.Assertion{kind: :projection_violation, name: ThrowingProjection}
             },
             result.failure_reason
           )
  end

  @tag :capture_log
  test "a teardown that exits does not crash the run (best-effort)" do
    assert {:ok, result} = run(NoopModel, :teardown_exit)
    assert result.success
  end

  @tag :capture_log
  test "a teardown that throws does not crash the run (best-effort)" do
    assert {:ok, result} = run(NoopModel, :teardown_throw)
    assert result.success
  end
end
