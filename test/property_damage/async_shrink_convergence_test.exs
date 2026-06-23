defmodule PropertyDamage.AsyncShrinkConvergenceTest do
  @moduledoc """
  End-to-end tests for continuous async-observation checking (DR-025): a
  `@trigger every:` assertion fires on asynchronously-observed events (here, a
  resource poller's injected events), so a violation is reported AT the offending
  event with the injecting command's `command_index`, giving the shrinker a tight
  truncation target.

  These are written failing-first against the pre-DR-025 engine: today the
  asynchronous event paths fold events into projection state but never evaluate
  `@trigger` assertions (the P2 finding), so the overshoot below is undetected and
  the run wrongly succeeds.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{EventQueue, Executor, Sequence, Shrinker}

  defmodule Bumped, do: defstruct([])

  defmodule Bump do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # A no-op command used as removable noise around the offending command, so the
  # shrinker has something to converge away from.
  defmodule Noise do
    @behaviour PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # Accumulating safety projection (the DR-024 accumulator contract): tracks the
  # maximum count ever observed, and bounds it at 1 via an `every:` assertion that
  # must fire on every observed Bumped, async ones included.
  defmodule MaxCountProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0, max: 0}

    @impl true
    def apply(%{count: c, max: m} = state, %Bumped{}) do
      %{state | count: c + 1, max: max(m, c + 1)}
    end

    def apply(state, _), do: state

    @trigger every: Bumped
    def assert_count_at_most_one(state, _event) do
      if state.max > 1 do
        PropertyDamage.fail!("count exceeded 1", max: state.max)
      end
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Bump, Noise]
    @impl true
    def command_sequence_projection, do: MaxCountProjection
  end

  # `Bump` starts a resource poller that asynchronously injects TWO Bumped events
  # (count 0 -> 1 -> 2, so max reaches 2). The overshoot is observable ONLY through
  # the asynchronous poller events; nothing is returned synchronously. `Noise`
  # does nothing.
  defmodule PollerOvershootAdapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Bump{}, ctx) do
      ctx.start_poller.(
        poll_fn: fn -> :tick end,
        handler: fn _ -> {:done, [%Bumped{}, %Bumped{}]} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, []}
    end

    @impl true
    def execute(%Noise{}, _ctx), do: {:ok, []}
  end

  defp run_seq(seq, model, adapter) do
    {:ok, queue} = EventQueue.start_link()

    try do
      Executor.run(seq, model, adapter, event_queue: queue)
    after
      EventQueue.stop(queue)
    end
  end

  test "an every: assertion fires on an asynchronously-observed (poller) event, at the injecting command's index" do
    # Bump is at index 0; its poller injects the overshoot.
    {:ok, result} = run_seq(Sequence.linear([%Bump{}]), Model, PollerOvershootAdapter)

    refute result.success,
           "expected the poller-injected overshoot to trip every: count_at_most_one"

    assert {:assertion_failed, :count_at_most_one, _exception} = result.failure_reason
    assert result.failed_at_index == 0, "the failure should be located at the injecting command"
    assert result.projections[MaxCountProjection].max == 2
  end

  test "an async overshoot shrinks to a minimal reproduction ending at the offending command" do
    # Noise, Noise, Bump: the Bump at index 2 starts the overshooting poller; the
    # leading Noise commands are removable.
    seq = Sequence.linear([%Noise{}, %Noise{}, %Bump{}])

    {:ok, result} = run_seq(seq, Model, PollerOvershootAdapter)

    refute result.success, "expected the async overshoot to fail the run"
    assert {:assertion_failed, :count_at_most_one, _} = result.failure_reason
    assert result.failed_at_index == 2

    {:ok, queue} = EventQueue.start_link()

    shrunk =
      try do
        Shrinker.shrink(seq,
          failed_at_index: result.failed_at_index,
          failure_reason: result.failure_reason,
          model: Model,
          adapter: PollerOvershootAdapter,
          event_queue: queue
        )
      after
        EventQueue.stop(queue)
      end

    commands = Sequence.to_list(shrunk.sequence)

    assert commands == [%Bump{}],
           "expected convergence to the single offending command, got: #{inspect(commands)}"
  end

  # ---------------------------------------------------------------------------
  # The opt-out: every: :command is scoped to commands, so it never fires on an
  # event (own or async). DR-025 must not change that.
  # ---------------------------------------------------------------------------
  defmodule CommandScopedProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0, max: 0}

    @impl true
    def apply(%{count: c, max: m} = state, %Bumped{}) do
      %{state | count: c + 1, max: max(m, c + 1)}
    end

    def apply(state, _), do: state

    # The opt-out guarantee: an every: :command assertion is triggered only by
    # COMMAND steps, never by an event (own or asynchronously-observed). So its
    # second argument is always the command; it must never be a %Bumped{}. This
    # is race-free regardless of when the poller's events fold in.
    @trigger every: :command
    def assert_triggered_only_by_commands(_state, command_or_event) do
      if match?(%Bumped{}, command_or_event) do
        PropertyDamage.fail!("every: :command was triggered by an event",
          arg: command_or_event
        )
      end
    end
  end

  defmodule CommandScopedModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Bump, Noise]
    @impl true
    def command_sequence_projection, do: CommandScopedProjection
  end

  test "every: :command is not triggered by asynchronously-observed events (the opt-out)" do
    {:ok, result} =
      run_seq(Sequence.linear([%Bump{}]), CommandScopedModel, PollerOvershootAdapter)

    assert result.success,
           "every: :command must never be triggered by an event: #{inspect(result.failure_reason)}"

    # The async overshoot still folded into projection state; it was simply never
    # passed to the command-scoped assertion as a trigger.
    assert result.projections[CommandScopedProjection].max == 2
  end

  defp run_seq_mode(seq, model, adapter, mode) do
    {:ok, queue} = EventQueue.start_link()

    try do
      Executor.run(seq, model, adapter, event_queue: queue, assertion_mode: mode)
    after
      EventQueue.stop(queue)
    end
  end

  test ":record mode accumulates an async violation (with source/index) instead of halting" do
    {:ok, result} =
      run_seq_mode(Sequence.linear([%Bump{}]), Model, PollerOvershootAdapter, :record)

    refute result.success
    assert result.failure_reason == nil

    assert Enum.any?(result.assertion_failures, fn f ->
             f.assertion_name == :count_at_most_one and f.command_index == 0
           end),
           "expected a recorded async failure at command_index 0: #{inspect(result.assertion_failures)}"
  end

  test ":disabled mode skips the async check entirely" do
    {:ok, result} =
      run_seq_mode(Sequence.linear([%Bump{}]), Model, PollerOvershootAdapter, :disabled)

    assert result.success
  end
end
