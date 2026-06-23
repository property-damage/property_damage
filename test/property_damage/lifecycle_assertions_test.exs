defmodule PropertyDamage.LifecycleAssertionsTest do
  @moduledoc """
  End-to-end tests for `@trigger at:` lifecycle-boundary assertions (DR-024)
  through `Executor.run`.

  Covers the engine call sites: the `:startup` gate (on the initial `init/0`
  state, before command 1) and the `:teardown` checkpoint (on the fully-settled
  state, after both poller-finalize steps, before `Adapter.teardown/1`, on the
  clean-completion path only). A genuine `@poll_state` liveness timeout preempts
  the `:teardown` checkpoint; a `@poll_state` that passes still reaches it.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{Executor, Sequence}

  defmodule Bumped, do: defstruct([])

  defmodule Bump do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # ---------------------------------------------------------------------------
  # An accumulating safety projection: it tracks the MAXIMUM count ever observed
  # (the accumulator contract, DR-024 §11.4) so a transient overshoot leaves a
  # permanent trace for the settled-state check.
  # ---------------------------------------------------------------------------
  defmodule MaxCountProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0, max: 0}

    @impl true
    def apply(%{count: c, max: m} = state, %Bumped{}) do
      %{state | count: c + 1, max: max(m, c + 1)}
    end

    def apply(state, _), do: state

    @trigger at: :teardown
    def assert_count_at_most_one(state, _phase) do
      if state.max > 1 do
        PropertyDamage.fail!("count exceeded 1 at settle", max: state.max)
      end
    end
  end

  defmodule MaxCountModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Bump]
    @impl true
    def command_sequence_projection, do: MaxCountProjection
  end

  defp run_seq(seq, model, adapter) do
    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    try do
      Executor.run(seq, model, adapter, event_queue: queue)
    after
      PropertyDamage.EventQueue.stop(queue)
    end
  end

  # ===========================================================================
  # Cluster 2 — the teardown checkpoint
  # ===========================================================================

  # One command emits two Bumped events: the synchronous fold reaches max = 2,
  # which persists to the settled state.
  defmodule DoubleBumpAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Bump{}, _ctx), do: {:ok, [%Bumped{}, %Bumped{}]}
  end

  defmodule SingleBumpAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Bump{}, _ctx), do: {:ok, [%Bumped{}]}
  end

  test "a teardown check fails as a named assertion failure (not a poll timeout) when the settled state violates it" do
    {:ok, result} = run_seq(Sequence.linear([%Bump{}]), MaxCountModel, DoubleBumpAdapter)

    refute result.success
    assert {:assertion_failed, :count_at_most_one, _exception} = result.failure_reason
    assert result.failed_at_index == nil
    assert is_list(result.stacktrace)
  end

  test "a teardown check passes when the settled state is within bound" do
    {:ok, result} = run_seq(Sequence.linear([%Bump{}]), MaxCountModel, SingleBumpAdapter)

    assert result.success, "expected success, got: #{inspect(result.failure_reason)}"
  end

  # A teardown assertion that always fails, paired with an adapter that errors:
  # the run aborts before settling, so the teardown checkpoint must NOT run and
  # the reported failure is the proximate adapter error.
  defmodule NeverProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}

    @trigger at: :teardown
    def assert_never(_state, _phase) do
      PropertyDamage.fail!("teardown must not run on an aborted run")
    end
  end

  defmodule NeverModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Bump]
    @impl true
    def command_sequence_projection, do: NeverProjection
  end

  defmodule ErroringAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Bump{}, _ctx), do: {:error, :boom}
  end

  test "the teardown checkpoint does not run when the run aborts early" do
    {:ok, result} = run_seq(Sequence.linear([%Bump{}]), NeverModel, ErroringAdapter)

    refute result.success
    assert {:adapter_error, :boom} = result.failure_reason
    refute match?({:assertion_failed, :never, _}, result.failure_reason)
  end

  # ===========================================================================
  # Cluster 3 — "settled" includes resource-poller events after the last command
  # ===========================================================================

  # The command emits one Bumped synchronously, then a resource poller emits a
  # SECOND Bumped after the command returns. If the teardown check ran before
  # finalize_resource_pollers, it would see max = 1 and pass; it sees max = 2,
  # proving it observes the fully-settled (post-poller) state.
  defmodule LateBumpAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Bump{}, ctx) do
      ctx.start_poller.(
        poll_fn: fn -> :tick end,
        handler: fn _ -> {:done, [%Bumped{}]} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, [%Bumped{}]}
    end
  end

  test "the teardown check observes events folded from a resource poller after the last command" do
    {:ok, result} = run_seq(Sequence.linear([%Bump{}]), MaxCountModel, LateBumpAdapter)

    refute result.success,
           "expected the late poller bump to be folded into the settled state and trip the check"

    assert {:assertion_failed, :count_at_most_one, _} = result.failure_reason
    assert result.projections[MaxCountProjection].max == 2
  end

  # ===========================================================================
  # Cluster 4 — liveness timeout preempts the teardown checkpoint
  # ===========================================================================

  defmodule Initiated, do: defstruct([])

  defmodule Initiate do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # Liveness (@poll_state) that never resolves, plus a teardown safety check
  # that would always fail. A genuine liveness timeout preempts the checkpoint.
  defmodule LivenessAndSafetyProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{confirmed: false}
    @impl true
    def apply(state, %Initiated{}), do: state
    def apply(state, _), do: state

    @poll_state after: Initiated, timeout: {150, :milliseconds}, interval: {10, :milliseconds}
    def confirmed_eventually(_state, %Initiated{}) do
      fn s -> s.confirmed end
    end

    @trigger at: :teardown
    def assert_would_fail(_state, _phase) do
      PropertyDamage.fail!("teardown should be preempted by the liveness timeout")
    end
  end

  defmodule LivenessSafetyModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Initiate]
    @impl true
    def command_sequence_projection, do: LivenessAndSafetyProjection
    @impl true
    def assertion_projections, do: []
  end

  defmodule SilentAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%Initiate{}, _ctx), do: {:ok, [%Initiated{}]}
  end

  test "a genuine @poll_state liveness timeout preempts the teardown checkpoint" do
    {:ok, result} = run_seq(Sequence.linear([%Initiate{}]), LivenessSafetyModel, SilentAdapter)

    refute result.success
    assert {:poll_timeout, info} = result.failure_reason
    assert info.triggered_by.assertion_name == :confirmed_eventually
    refute match?({:assertion_failed, :would_fail, _}, result.failure_reason)
  end

  defmodule Confirmed, do: defstruct([])

  # Liveness that DOES resolve (the poller confirms), so the run reaches the
  # settled checkpoint and the teardown safety check fires.
  defmodule ConfirmingAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Initiate{}, ctx) do
      ctx.start_poller.(
        poll_fn: fn -> :tick end,
        handler: fn _ -> {:done, [%Confirmed{}]} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, [%Initiated{}]}
    end
  end

  defmodule ConfirmableProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{confirmed: false}
    @impl true
    def apply(state, %Confirmed{}), do: %{state | confirmed: true}
    def apply(state, _), do: state

    @poll_state after: Initiated, timeout: {1000, :milliseconds}, interval: {10, :milliseconds}
    def confirmed_eventually(_state, %Initiated{}) do
      fn s -> s.confirmed end
    end

    @trigger at: :teardown
    def assert_teardown_reached(_state, _phase) do
      PropertyDamage.fail!("teardown reached after liveness passed")
    end
  end

  defmodule ConfirmableModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Initiate]
    @impl true
    def command_sequence_projection, do: ConfirmableProjection
  end

  test "a @poll_state that resolves still reaches the teardown checkpoint" do
    {:ok, result} = run_seq(Sequence.linear([%Initiate{}]), ConfirmableModel, ConfirmingAdapter)

    refute result.success
    assert {:assertion_failed, :teardown_reached, _} = result.failure_reason
  end

  # ===========================================================================
  # Cluster 5 — the startup gate
  # ===========================================================================

  defmodule FailingStartupProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{ready: false}

    @trigger at: :startup
    def assert_ready(state, _phase) do
      unless state.ready do
        PropertyDamage.fail!("startup precondition not met")
      end
    end
  end

  defmodule FailingStartupModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Bump]
    @impl true
    def command_sequence_projection, do: FailingStartupProjection
  end

  # Records whether execute/2 ever ran, to prove the startup gate halted before
  # command 1.
  defmodule RecordingAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(_config) do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      {:ok, %{agent: agent}}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Bump{}, ctx) do
      Agent.update(ctx.agent, &(&1 + 1))
      {:ok, [%Bumped{}]}
    end

    def executions(ctx), do: Agent.get(ctx.agent, & &1)
  end

  test "a failing @trigger at: :startup check halts the run before command 1" do
    # Drive setup/teardown ourselves so we can inspect the execution counter.
    {:ok, ctx} = RecordingAdapter.setup(%{})
    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    result =
      try do
        Executor.execute_sequence(
          Sequence.linear([%Bump{}]),
          FailingStartupModel,
          RecordingAdapter,
          ctx,
          queue
        )
      after
        PropertyDamage.EventQueue.stop(queue)
      end

    refute result.success
    assert {:assertion_failed, :ready, _} = result.failure_reason
    assert result.failed_at_index == nil
    assert RecordingAdapter.executions(ctx) == 0, "command 1 must not run after a startup halt"
  end

  defmodule PassingStartupProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{ready: true}

    @trigger at: :startup
    def assert_ready(state, _phase) do
      unless state.ready, do: PropertyDamage.fail!("not ready")
    end
  end

  defmodule PassingStartupModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Bump]
    @impl true
    def command_sequence_projection, do: PassingStartupProjection
  end

  test "a passing @trigger at: :startup check lets the run proceed" do
    {:ok, result} = run_seq(Sequence.linear([%Bump{}]), PassingStartupModel, SingleBumpAdapter)

    assert result.success, "expected success, got: #{inspect(result.failure_reason)}"
  end

  # ===========================================================================
  # Cluster 7 — branching: persistent overshoot caught on the merged state
  # ===========================================================================

  test "a persistent overshoot across branches is caught at :teardown on the merged state" do
    # Two independent branches each emit one Bumped; the merged settled state
    # has max = 2, tripping the teardown safety check.
    seq = %Sequence{prefix: [], branches: [[%Bump{}], [%Bump{}]], suffix: []}

    {:ok, result} = run_seq(seq, MaxCountModel, SingleBumpAdapter)

    refute result.success
    assert {:assertion_failed, :count_at_most_one, _} = result.failure_reason
  end
end
