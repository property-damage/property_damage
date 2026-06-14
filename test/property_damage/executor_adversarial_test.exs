defmodule PropertyDamage.ExecutorAdversarialTest do
  @moduledoc """
  Adversarial fixtures: the executor must turn misbehaving adapters/projections
  into graceful failure reports, never crash the run. Several of these paths
  used to raise outside the per-command rescue (CaseClauseError on a malformed
  adapter return; a raising projection).
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Sequence}

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

  # An adapter whose behaviour is dictated by the command tag carried in config.
  defmodule Adversary do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Cmd{}, %{behaviour: :raise}), do: raise("adapter boom")
    def execute(%Cmd{}, %{behaviour: :malformed_atom}), do: :garbage
    def execute(%Cmd{}, %{behaviour: :malformed_ok}), do: {:ok, :not_a_list}
    def execute(%Cmd{}, %{behaviour: :sync_retry}), do: {:retry, :not_ready}
    def execute(%Cmd{}, %{behaviour: :error}), do: {:error, :nope}
    def execute(%Cmd{}, _ctx), do: {:ok, [%Ev{tag: :x}]}

    @impl true
    def teardown(_ctx), do: :ok
  end

  defp run(model, behaviour) do
    seq = Sequence.linear([%Cmd{tag: :x}])
    Executor.run(seq, model, Adversary, adapter_config: %{behaviour: behaviour})
  end

  test "a raising adapter becomes a graceful adapter_error, not a crash" do
    assert {:ok, result} = run(NoopModel, :raise)
    assert result.failed_at_index == 0
    assert match?({:adapter_error, %RuntimeError{message: "adapter boom"}}, result.failure_reason)
  end

  test "a malformed atom return is reported, not a CaseClauseError" do
    assert {:ok, result} = run(NoopModel, :malformed_atom)
    assert result.failed_at_index == 0
    assert result.failure_reason == {:malformed_adapter_return, :garbage}
  end

  test "an {:ok, non-list} return is reported as malformed" do
    assert {:ok, result} = run(NoopModel, :malformed_ok)
    assert result.failed_at_index == 0
    assert result.failure_reason == {:malformed_adapter_return, {:ok, :not_a_list}}
  end

  test "a sync command returning {:retry, _} is reported, not a CaseClauseError" do
    assert {:ok, result} = run(NoopModel, :sync_retry)
    assert result.failed_at_index == 0
    assert result.failure_reason == {:malformed_adapter_return, {:retry, :not_ready}}
  end

  test "a plain {:error, reason} is reported as adapter_error" do
    assert {:ok, result} = run(NoopModel, :error)
    assert result.failed_at_index == 0
    assert result.failure_reason == {:adapter_error, :nope}
  end

  test "a raising projection becomes a projection_violation, not a crash" do
    assert {:ok, result} = run(RaisingProjectionModel, :ok)
    assert result.failed_at_index == 0
    assert match?({:projection_violation, RaisingProjection, _}, result.failure_reason)
  end
end
