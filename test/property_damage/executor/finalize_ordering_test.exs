defmodule PropertyDamage.Executor.FinalizeOrderingTest do
  @moduledoc """
  Ordering guards for the executor's finalize chain (DR-029 pre-work).

  The finalize chain runs, in order:

      finalize_pollers (@poll_state drain + async checks)
        -> finalize_resource_pollers
        -> settle_event_queue (drain injector/poller events + async checks)
        -> finalize_after_settle
        -> run_phase_assertions(:teardown)

  When more than one failure is live at finalize time, a strict precedence
  decides which one is reported (DR-024/025/026):

      async-halt (drain)  >  poll-timeout  >  settle-halt  >  resource-error  >  teardown-assertion

  These tests pin that precedence (and the `command_index` carried by the two
  async cases) by constructing scenarios where two competing failures fire at
  once and asserting which one wins. They exist so the P3 cohesive-module
  strangler (extracting `Executor.Finalization`) cannot silently reorder the
  chain: any swap of two adjacent decision points flips a winner and turns one
  of these red. They are expected GREEN on HEAD, where the behavior already
  exists; their job is to lock it.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{EventQueue, Executor, Sequence}

  # --- events -----------------------------------------------------------------
  defmodule Bumped, do: defstruct([])
  defmodule Started, do: defstruct([])

  # --- a command that the adapters interpret to set up each scenario ----------
  defmodule Trigger do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defp run_seq(seq, model, adapter) do
    {:ok, queue} = EventQueue.start_link()

    try do
      Executor.run(seq, model, adapter, event_queue: queue)
    after
      EventQueue.stop(queue)
    end
  end

  # ===========================================================================
  # Guard 1 - async-halt (a poller event folded during the @poll_state await
  # drain trips an `every:` assertion) preempts the poll timeout, and is
  # reported at the injecting command's index.
  #
  # The chain checks `state.async_halt` (set inside finalize_pollers' drain)
  # BEFORE it inspects the poll timeout `halt_failure`. Reorder those two and
  # this scenario reports {:poll_timeout, _} instead.
  # ===========================================================================
  defmodule DrainHaltProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{count: 0, max: 0, confirmed: false}
    @impl true
    def apply(%{count: c, max: m} = s, %Bumped{}), do: %{s | count: c + 1, max: max(m, c + 1)}
    def apply(s, _), do: s

    # Liveness that never resolves: a poll-timeout candidate.
    @poll_state after: Started, timeout: {1000, :milliseconds}, interval: {10, :milliseconds}
    def confirm_eventually(_state, %Started{}), do: fn s -> s.confirmed end

    # Async safety: trips on the poller's second Bumped, observed during the drain.
    @trigger every: Bumped
    def assert_count_at_most_one(state, _event) do
      if state.max > 1, do: PropertyDamage.fail!("count exceeded 1", max: state.max)
    end
  end

  defmodule DrainHaltModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Trigger]
    @impl true
    def command_sequence_projection, do: DrainHaltProjection
  end

  defmodule DrainHaltAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Trigger{}, _ctx, runtime) do
      # Resource poller injects the overshoot asynchronously, but only on its
      # SECOND poll (the first returns :continue). The first poll fires at ~0ms,
      # the second one interval_ms later, by which time the synchronous per-command
      # injector drain has already passed. So the events are NOT folded at command
      # level; they land during the @poll_state await drain at finalize instead
      # (the Started event below starts that never-confirming poller), where the
      # incremental async check trips and sets async_halt.
      counter = :counters.new(1, [:atomics])

      runtime.start_poller.(
        poll_fn: fn ->
          :counters.add(counter, 1, 1)
          :counters.get(counter, 1)
        end,
        handler: fn n -> if n >= 2, do: {:done, [%Bumped{}, %Bumped{}]}, else: :continue end,
        interval_ms: 50,
        timeout_ms: 2000
      )

      {:ok, [%Started{}]}
    end
  end

  test "async-halt during the poll drain preempts the poll timeout, at the injecting command index" do
    {:ok, result} = run_seq(Sequence.linear([%Trigger{}]), DrainHaltModel, DrainHaltAdapter)

    refute result.success
    assert {:assertion_failed, :count_at_most_one, _} = result.failure_reason
    assert result.failed_at_index == 0

    refute match?({:poll_timeout, _}, result.failure_reason),
           "async-halt must win over the poll timeout"
  end

  # ===========================================================================
  # Guard 2 - a poll timeout preempts the rest of the chain (finalize_resource_
  # pollers / settle / teardown never run). Here a resource poller error is the
  # loser: the timeout short-circuits before resource pollers are finalized.
  # ===========================================================================
  defmodule PollVsResourceProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{confirmed: false}
    @impl true
    def apply(s, _), do: s

    @poll_state after: Started, timeout: {200, :milliseconds}, interval: {10, :milliseconds}
    def confirm_eventually(_state, %Started{}), do: fn s -> s.confirmed end
  end

  defmodule PollVsResourceModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Trigger]
    @impl true
    def command_sequence_projection, do: PollVsResourceProjection
  end

  defmodule PollVsResourceAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Trigger{}, _ctx, runtime) do
      # A resource poller that errors. It must be preempted by the poll timeout.
      runtime.start_poller.(
        poll_fn: fn -> :fail end,
        handler: fn _ -> {:error, :resource_boom} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, [%Started{}]}
    end
  end

  test "a poll timeout preempts a resource-poller error" do
    {:ok, result} =
      run_seq(Sequence.linear([%Trigger{}]), PollVsResourceModel, PollVsResourceAdapter)

    refute result.success
    assert {:poll_timeout, info} = result.failure_reason
    assert info.triggered_by.assertion_name == :confirm_eventually

    refute match?({:resource_poller_error, _}, result.failure_reason),
           "the poll timeout must preempt the resource-poller error"
  end

  # ===========================================================================
  # Guard 3 - a settle-halt (an `every:` assertion tripping on a poller event
  # folded during settle_event_queue) preempts a resource-poller error, and is
  # reported at the injecting command's index.
  #
  # No @poll_state poller here, so finalize_pollers is a no-op; both resource
  # pollers are finalized, then the settle drain folds poller-1's events. The
  # chain checks the settle-halt BEFORE the captured resource_halt.
  # ===========================================================================
  defmodule SettleVsResourceProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{count: 0, max: 0}
    @impl true
    def apply(%{count: c, max: m} = s, %Bumped{}), do: %{s | count: c + 1, max: max(m, c + 1)}
    def apply(s, _), do: s

    @trigger every: Bumped
    def assert_count_at_most_one(state, _event) do
      if state.max > 1, do: PropertyDamage.fail!("count exceeded 1", max: state.max)
    end
  end

  defmodule SettleVsResourceModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Trigger]
    @impl true
    def command_sequence_projection, do: SettleVsResourceProjection
  end

  defmodule SettleVsResourceAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Trigger{}, _ctx, runtime) do
      # Poller 1: injects the overshoot on its second poll (the first returns
      # :continue), so the events arrive after the per-command drain has passed and
      # are not folded at command level. finalize_resource_pollers awaits this
      # poller, then settle_event_queue folds its events and the incremental async
      # check trips -> settle-halt.
      counter = :counters.new(1, [:atomics])

      runtime.start_poller.(
        poll_fn: fn ->
          :counters.add(counter, 1, 1)
          :counters.get(counter, 1)
        end,
        handler: fn n -> if n >= 2, do: {:done, [%Bumped{}, %Bumped{}]}, else: :continue end,
        interval_ms: 50,
        timeout_ms: 2000
      )

      # Poller 2: errors -> a resource_halt that must lose to the settle-halt.
      runtime.start_poller.(
        poll_fn: fn -> :fail end,
        handler: fn _ -> {:error, :resource_boom} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, []}
    end
  end

  test "a settle-halt preempts a resource-poller error, at the injecting command index" do
    {:ok, result} =
      run_seq(Sequence.linear([%Trigger{}]), SettleVsResourceModel, SettleVsResourceAdapter)

    refute result.success
    assert {:assertion_failed, :count_at_most_one, _} = result.failure_reason
    assert result.failed_at_index == 0

    refute match?({:resource_poller_error, _}, result.failure_reason),
           "the settle-halt must preempt the resource-poller error"
  end

  # ===========================================================================
  # Guard 4 - a resource-poller error preempts a teardown (@trigger at:) safety
  # check. finalize_after_settle inspects resource_halt BEFORE running the
  # teardown checkpoint; reorder them and the named assertion wins instead.
  # ===========================================================================
  defmodule ResourceVsTeardownProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{count: 0, max: 0}
    @impl true
    def apply(%{count: c, max: m} = s, %Bumped{}), do: %{s | count: c + 1, max: max(m, c + 1)}
    def apply(s, _), do: s

    @trigger at: :teardown
    def assert_count_at_most_one(state, _phase) do
      if state.max > 1, do: PropertyDamage.fail!("count exceeded 1 at settle", max: state.max)
    end
  end

  defmodule ResourceVsTeardownModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Trigger]
    @impl true
    def command_sequence_projection, do: ResourceVsTeardownProjection
  end

  defmodule ResourceVsTeardownAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Trigger{}, _ctx, runtime) do
      # Errors at finalize_resource_pollers.
      runtime.start_poller.(
        poll_fn: fn -> :fail end,
        handler: fn _ -> {:error, :resource_boom} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      # Two synchronous Bumped push max to 2, so the teardown check WOULD fail
      # if it were reached.
      {:ok, [%Bumped{}, %Bumped{}]}
    end
  end

  test "a resource-poller error preempts a failing teardown checkpoint" do
    {:ok, result} =
      run_seq(Sequence.linear([%Trigger{}]), ResourceVsTeardownModel, ResourceVsTeardownAdapter)

    refute result.success
    assert {:resource_poller_error, :resource_boom} = result.failure_reason

    refute match?({:assertion_failed, _, _}, result.failure_reason),
           "the resource-poller error must preempt the teardown assertion"
  end
end
