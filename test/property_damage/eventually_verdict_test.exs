defmodule PropertyDamage.EventuallyVerdictTest do
  # An `@eventually` predicate returns a verdict (DR-052 item 6): `nil` and
  # `false` mean "not yet", `{:fail, reason}` means "never" and ends the
  # window at once as a check failure with that reason, and a raise inside
  # the predicate is a check failure at once naming the check, the poll count
  # and the exception. Neither waits out the window or reports a timeout.
  use ExUnit.Case, async: true

  alias PropertyDamage.{CheckFailed, Executor, Failure}

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
    def apply(state, %PaymentInitiated{id: id}), do: put_in(state.status[id], :failed)
    def apply(state, _), do: state

    # Two targets compare on something; they agree on the status.
    @compare every: 1
    def statuses(state, _root), do: state.status
  end

  # A payment that reached :failed can never become :confirmed.
  defmodule Never do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{status: %{}}

    @impl true
    def apply(state, %PaymentInitiated{id: id}), do: put_in(state.status[id], :failed)
    def apply(state, _), do: state

    @eventually after: PaymentInitiated, timeout: {5, :seconds}, interval: {10, :milliseconds}
    def payment_confirmed(_state, %PaymentInitiated{id: id}) do
      fn s ->
        case get_in(s, [:status, id]) do
          :confirmed -> true
          :failed -> {:fail, "payment #{id} reached :failed"}
          _pending -> false
        end
      end
    end
  end

  # A partial predicate: it reads a key the state never has.
  defmodule Raising do
    use PropertyDamage.Model.Projection

    @eventually after: PaymentInitiated, timeout: {5, :seconds}, interval: {10, :milliseconds}
    def payment_settled(_state, %PaymentInitiated{}) do
      fn s -> Map.fetch!(s, :settlements) != %{} end
    end
  end

  for check <- [Never, Raising] do
    defmodule Module.concat(check, Model) do
      @behaviour PropertyDamage.Model
      @impl true
      def commands, do: [PropertyDamage.EventuallyVerdictTest.InitiatePayment]
      @impl true
      def command_sequence_projection, do: PropertyDamage.EventuallyVerdictTest.Payments
      @impl true
      def check_projections, do: [unquote(check)]
    end
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

  defp run_executor(model, opts \\ []) do
    seq = PropertyDamage.Sequence.linear([%InitiatePayment{id: "pay_1"}])
    {:ok, queue} = PropertyDamage.EventQueue.start_link()
    started = System.monotonic_time(:millisecond)

    try do
      {:ok, result} = Executor.run(seq, model, Adapter, [event_queue: queue] ++ opts)
      {result, System.monotonic_time(:millisecond) - started}
    after
      PropertyDamage.EventQueue.stop(queue)
    end
  end

  defp exception(%Failure{} = failure) do
    case Failure.detail(failure) do
      {exception, _stacktrace} -> exception
      exception -> exception
    end
  end

  test "{:fail, reason} ends the window at once as a check failure with that reason" do
    {result, elapsed} = run_executor(Never.Model)

    refute result.success

    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :payment_confirmed}} =
             result.failure_reason

    assert %CheckFailed{message: "payment pay_1 reached :failed"} =
             exception(result.failure_reason)

    assert result.failed_at_index == 0
    assert elapsed < 2_000, "the failure waited for the window (#{elapsed} ms)"
  end

  test "a raise in the predicate fails at once, naming the check, the poll and the exception" do
    {result, elapsed} = run_executor(Raising.Model)

    refute result.success

    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :payment_settled}} =
             result.failure_reason

    message = Exception.message(exception(result.failure_reason))
    assert message =~ "payment_settled"
    assert message =~ "poll 1"
    assert message =~ "KeyError"
    assert elapsed < 2_000, "the failure waited for the window (#{elapsed} ms)"
  end

  test "under check_mode: :record the never is recorded as a check failure" do
    {result, _elapsed} = run_executor(Never.Model, check_mode: :record)

    assert [%{check_name: :payment_confirmed} = recorded] = result.check_failures
    assert %CheckFailed{message: "payment pay_1 reached :failed"} = recorded.reason
    assert recorded.command_index == 0
  end

  test "with two targets the variant fails at the step that opened the window" do
    assert {:error, %PropertyDamage.FailureReport{} = report} =
             PropertyDamage.run(
               model: Never.Model,
               targets: [{Adapter, name: "a"}, {Adapter, name: "b"}],
               seed: 1,
               max_commands: 1,
               max_runs: 1,
               shrink: false,
               validate: false
             )

    assert %Failure{type: %Failure.Check{kind: :check_failed, name: :payment_confirmed}} =
             report.failure_reason
  end
end
