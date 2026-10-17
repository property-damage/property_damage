defmodule PropertyDamage.EventuallyReturnTest do
  # An `@eventually` function must return the predicate the poller calls. A
  # function that returns anything else is a check failure at the step that
  # triggered it, handled like a synchronous check under the run's
  # `check_mode:`, instead of a window that times out behind a logged
  # BadFunctionError on every poll.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Failure}

  defmodule PaymentInitiated, do: defstruct([:id])

  defmodule InitiatePayment do
    @behaviour PropertyDamage.Command
    defstruct [:id]
    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{id: "pay_1"})
  end

  defmodule Payments do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{status: %{}}

    @impl true
    def apply(state, %PaymentInitiated{id: id}), do: put_in(state.status[id], :pending)
    def apply(state, _), do: state

    # The predicate is missing: the function answers the question itself.
    @eventually after: PaymentInitiated,
                timeout: {2, :seconds},
                interval: {10, :milliseconds}
    def payment_confirmed(state, %PaymentInitiated{id: id}) do
      state.status[id] == :confirmed
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [InitiatePayment]
    @impl true
    def command_sequence_projection, do: Payments
    @impl true
    def check_projections, do: [Payments]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    @impl true
    def setup(config), do: {:ok, config}
    @impl true
    def teardown(_ctx), do: :ok
    @impl true
    def execute(%InitiatePayment{id: id}, _ctx, _runtime), do: {:ok, [%PaymentInitiated{id: id}]}
  end

  defp run_executor(opts) do
    seq = PropertyDamage.Sequence.linear([%InitiatePayment{id: "pay_1"}])
    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    try do
      Executor.run(seq, Model, Adapter, [event_queue: queue] ++ opts)
    after
      PropertyDamage.EventQueue.stop(queue)
    end
  end

  test "an @eventually that returns no predicate fails at its step, before the window" do
    started = System.monotonic_time(:millisecond)
    {:ok, result} = run_executor([])
    elapsed = System.monotonic_time(:millisecond) - started

    refute result.success

    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :payment_confirmed}} =
             result.failure_reason

    detail = inspect(Failure.detail(result.failure_reason))
    assert detail =~ "1-arity", "the message names the required shape: #{detail}"
    assert detail =~ "false", "the message names the value returned: #{detail}"
    assert result.failed_at_index == 0
    assert elapsed < 1_000, "the failure waited for the window (#{elapsed} ms)"
  end

  test "under check_mode: :record the failure is recorded and the run goes on" do
    {:ok, result} = run_executor(check_mode: :record)

    assert Enum.any?(result.check_failures, &(&1.check_name == :payment_confirmed))
    refute match?(%Failure{type: %Failure.Check{kind: :poll_timeout}}, result.failure_reason)
  end

  @tag :capture_log
  test "under check_mode: :log the run goes on without a poller" do
    {:ok, result} = run_executor(check_mode: :log)

    assert result.success
    assert result.check_failures == []
    refute match?(%Failure{type: %Failure.Check{kind: :poll_timeout}}, result.failure_reason)
  end

  test "through run/1 the report names the check and the step" do
    assert {:error, %PropertyDamage.FailureReport{} = report} =
             PropertyDamage.run(
               model: Model,
               targets: [Adapter],
               seed: 1,
               max_commands: 1,
               max_runs: 1,
               shrink: false,
               validate: false
             )

    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :payment_confirmed}} =
             report.failure_reason

    assert report.failed_at_index == 0
  end
end
