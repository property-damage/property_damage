defmodule PropertyDamage.EventualConsistencyTest do
  @moduledoc """
  End-to-end tests for the @poll_state eventual-consistency pipeline through
  Executor.run. These exercise the R4 fixes:

    1. @poll_state assertions no longer crash the run on the first command
       (the run_projection_assertions type filter)
    2. a poll predicate can observe events that arrive AFTER the last command
       (the drain-and-refresh finalization loop)
    3. a poll timeout produces a FailureReport instead of crashing
       handle_failure with a KeyError (projections_before + nil index)
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Executor
  alias PropertyDamage.Failure

  defmodule Events do
    defmodule PaymentInitiated, do: defstruct([:id])
    defmodule PaymentConfirmed, do: defstruct([:id])
  end

  defmodule InitiatePayment do
    @behaviour PropertyDamage.Command
    defstruct [:id]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{id: "pay_1"})
  end

  defmodule PaymentProjection do
    use PropertyDamage.Model.Projection

    alias Events.{PaymentConfirmed, PaymentInitiated}

    @impl true
    def init, do: %{status: %{}}

    @impl true
    def apply(state, %PaymentInitiated{id: id}), do: put_in(state.status[id], :pending)
    def apply(state, %PaymentConfirmed{id: id}), do: put_in(state.status[id], :confirmed)
    def apply(state, _), do: state

    # Eventual consistency: the payment must become confirmed within the
    # window. The confirming event arrives via a resource poller AFTER the
    # command returns. @poll_state triggers on the PaymentInitiated EVENT.
    @poll_state after: PaymentInitiated,
                timeout: {300, :milliseconds},
                interval: {10, :milliseconds}
    def payment_eventually_confirmed(_state, %PaymentInitiated{id: id}) do
      fn s -> s.status[id] == :confirmed end
    end
  end

  defmodule PaymentSimulator do
    @behaviour PropertyDamage.Model.Simulator
    alias Events.PaymentInitiated

    @impl true
    def simulate(%InitiatePayment{id: id}, _state), do: [%PaymentInitiated{id: id}]
    def simulate(_, _), do: []
  end

  defmodule PaymentModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [InitiatePayment]
    @impl true
    def command_sequence_projection, do: PaymentProjection
    @impl true
    def assertion_projections, do: [PaymentProjection]
    @impl true
    def simulator, do: PaymentSimulator
  end

  # Adapter whose InitiatePayment starts a resource poller that emits the
  # confirming event after one tick, simulating an out-of-band confirmation.
  defmodule ConfirmingAdapter do
    use PropertyDamage.Adapter
    alias Events.{PaymentConfirmed, PaymentInitiated}

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%InitiatePayment{id: id}, _ctx, runtime) do
      runtime.start_poller.(
        poll_fn: fn -> :tick end,
        handler: fn _ -> {:done, [%PaymentConfirmed{id: id}]} end,
        interval_ms: 10,
        timeout_ms: 1000
      )

      {:ok, [%PaymentInitiated{id: id}]}
    end
  end

  # Adapter that never confirms: the poll must time out.
  defmodule SilentAdapter do
    use PropertyDamage.Adapter
    alias Events.PaymentInitiated

    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%InitiatePayment{id: id}, _ctx, _runtime) do
      {:ok, [%PaymentInitiated{id: id}]}
    end
  end

  defp run_executor(adapter) do
    seq = PropertyDamage.Sequence.linear([%InitiatePayment{id: "pay_1"}])
    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    try do
      Executor.run(seq, PaymentModel, adapter, event_queue: queue)
    after
      PropertyDamage.EventQueue.stop(queue)
    end
  end

  test "a @poll_state predicate observes a confirmation that arrives after the command" do
    {:ok, result} = run_executor(ConfirmingAdapter)

    assert result.success,
           "expected the eventual-consistency poll to succeed, got: #{inspect(result.failure_reason)}"

    assert result.projections[PaymentProjection].status["pay_1"] == :confirmed
  end

  test "a poll that never confirms times out and produces a report, not a crash" do
    {:ok, result} = run_executor(SilentAdapter)

    refute result.success

    assert %Failure{type: %Failure.Assertion{kind: :poll_timeout, detail: info}} =
             result.failure_reason

    assert info.triggered_by.assertion_name == :payment_eventually_confirmed
    # The crash these fixes prevent was a missing :projections_before key
    assert Map.has_key?(result, :projections_before)
  end

  # A probe command declared purely via `use ... execution: :probe` (no
  # legacy semantics/0). It must actually settle/retry; before the fix it
  # ran once as :sync.
  defmodule ProbeCheck do
    use PropertyDamage.Command, execution: :probe
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule ProbeEvents do
    defmodule Checked, do: defstruct([])
  end

  defmodule ProbeProjection do
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule ProbeModel do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [ProbeCheck]
    @impl true
    def command_sequence_projection, do: ProbeProjection
    @impl true
    def assertion_projections, do: []
  end

  defmodule RetryThenSucceedAdapter do
    @moduledoc "Returns {:retry, ...} a couple times, then {:ok, ...}."
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, Map.put(config, :counter, counter)}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%ProbeCheck{}, ctx, _runtime) do
      n = Agent.get_and_update(ctx.counter, fn n -> {n, n + 1} end)

      if n < 2 do
        {:retry, :not_ready}
      else
        {:ok, [%ProbeEvents.Checked{}]}
      end
    end
  end

  test "a spec-declared :probe command settles/retries (DR-019 at runtime)" do
    seq = PropertyDamage.Sequence.linear([%ProbeCheck{}])

    {:ok, result} =
      Executor.run(seq, ProbeModel, RetryThenSucceedAdapter,
        adapter_config: %{},
        # short interval so the two retries resolve quickly
        event_queue: nil
      )

    assert result.success,
           "probe should have retried to success, got: #{inspect(result.failure_reason)}"
  end

  test "the full run loop builds a FailureReport from a poll timeout" do
    # This drove handle_failure, which used to crash with a KeyError on the
    # poll-timeout result shape before any report could be built.
    result =
      PropertyDamage.run(
        model: PaymentModel,
        adapter: SilentAdapter,
        seed: 1,
        max_commands: 1,
        max_runs: 1,
        shrink: false,
        validate: false
      )

    assert {:error, %PropertyDamage.FailureReport{} = report} = result
    assert %Failure{type: %Failure.Assertion{kind: :poll_timeout}} = report.failure_reason

    # DR-030: a @poll_state liveness timeout is now attributed to the command
    # whose event opened the poll window (InitiatePayment at index 0), so the
    # shrinker keeps locality. (Previously reported as nil.)
    assert report.failed_at_index == 0
  end
end
