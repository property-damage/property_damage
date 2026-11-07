defmodule PropertyDamage.CheckVerdictTest do
  # A `@check` function's return is its verdict (DR-052 items 1, 1b, 4): a
  # truthy return passes, `nil` or `false` fails with a message that teaches
  # the rule, `{:fail, reason}` fails with that reason, and a bare exception
  # struct or an `{:error, _}` tuple fails with the grammar nudge. The rule
  # holds for `every:` and `at:` checks, in the executor, in forensics and in
  # the load-test worker.
  use ExUnit.Case, async: true

  alias PropertyDamage.{CheckFailed, Executor, Failure, Forensics, Sequence}
  alias PropertyDamage.LoadTest.{Metrics, Worker}

  defmodule Tick do
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Ticked, do: defstruct([])

  defmodule TickAdapter do
    use PropertyDamage.Adapter, default_timeout: 1_000

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Tick{}, _ctx, _runtime), do: {:ok, [%Ticked{}]}
  end

  defmodule StateProjection do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{ticks: 0}

    @impl true
    def apply(state, %Ticked{}), do: %{state | ticks: state.ticks + 1}
    def apply(state, _), do: state
  end

  # One check projection and one model per return value, each check named
  # after the value it returns.
  @returns [
    ok: :ok,
    truthy: %{ticks: 1},
    nil_return: nil,
    false_return: false,
    fail_text: {:fail, "net below fees"},
    fail_exception: {:fail, %ArgumentError{message: "custom reason"}},
    bare_exception: %ArgumentError{message: "bare"},
    error_tuple: {:error, :boom}
  ]

  for {name, value} <- @returns, timing <- [:every, :at] do
    projection = Module.concat(__MODULE__, Macro.camelize("#{name}_#{timing}_projection"))
    model = Module.concat(__MODULE__, Macro.camelize("#{name}_#{timing}_model"))

    if timing == :every do
      defmodule projection do
        use PropertyDamage.Model.Projection

        @check every: Ticked
        def unquote(name)(_state, _trigger), do: unquote(Macro.escape(value))
      end
    else
      defmodule projection do
        use PropertyDamage.Model.Projection

        @check at: :teardown
        def unquote(name)(_state, _trigger), do: unquote(Macro.escape(value))
      end
    end

    defmodule model do
      @behaviour PropertyDamage.Model.Simulator
      use PropertyDamage.Model

      @impl PropertyDamage.Model
      def commands, do: [Tick]

      @impl PropertyDamage.Model
      def command_sequence_projection, do: StateProjection

      @impl PropertyDamage.Model
      def check_projections, do: [unquote(projection)]

      @impl PropertyDamage.Model
      def simulator, do: __MODULE__

      @impl PropertyDamage.Model.Simulator
      def simulate(%Tick{}, _state), do: [%Ticked{}]
    end
  end

  defp model(name, timing),
    do: Module.concat(__MODULE__, Macro.camelize("#{name}_#{timing}_model"))

  defp run_executor(name, timing) do
    {:ok, queue} = PropertyDamage.EventQueue.start_link()

    try do
      {:ok, result} =
        Executor.run(Sequence.linear([%Tick{}]), model(name, timing), TickAdapter,
          event_queue: queue
        )

      result
    after
      PropertyDamage.EventQueue.stop(queue)
    end
  end

  # The exception a check failure carries, whether the runner kept its
  # stacktrace beside it or not.
  defp exception(%Failure{} = failure) do
    case Failure.detail(failure) do
      {exception, _stacktrace} -> exception
      exception -> exception
    end
  end

  @nil_message "check `nil_return` returned `nil`; a check passes by returning a truthy " <>
                 "value: a predicate, `condition or fail!(...)`, or a body that ends with `:ok`"
  @nudge "a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"

  describe "in the executor" do
    for timing <- [:every, :at] do
      @timing timing

      test "a truthy return passes (#{timing}:)" do
        for name <- [:ok, :truthy] do
          result = run_executor(name, @timing)
          assert result.success, "#{name}: #{inspect(result.failure_reason)}"
        end
      end

      test "nil fails with the message of DR-052 item 4 (#{timing}:)" do
        result = run_executor(:nil_return, @timing)
        refute result.success

        assert %Failure{type: %Failure.Check{kind: :check_failed, name: :nil_return}} =
                 result.failure_reason

        assert %CheckFailed{} = failure = exception(result.failure_reason)
        assert Exception.message(failure) == @nil_message
      end

      test "false fails, naming the check and the value (#{timing}:)" do
        result = run_executor(:false_return, @timing)
        refute result.success
        assert Failure.name(result.failure_reason) == :false_return

        assert Exception.message(exception(result.failure_reason)) =~
                 "check `false_return` returned `false`;"
      end

      test "{:fail, text} fails with that text (#{timing}:)" do
        result = run_executor(:fail_text, @timing)
        refute result.success
        assert Failure.name(result.failure_reason) == :fail_text

        assert %CheckFailed{message: "net below fees"} = exception(result.failure_reason)
      end

      test "{:fail, exception} fails with that exception (#{timing}:)" do
        result = run_executor(:fail_exception, @timing)
        refute result.success
        assert %ArgumentError{message: "custom reason"} = exception(result.failure_reason)
      end

      test "a bare exception struct and {:error, _} fail with the nudge (#{timing}:)" do
        for {name, shown} <- [bare_exception: "%ArgumentError{", error_tuple: "{:error, :boom}"] do
          result = run_executor(name, @timing)
          refute result.success, "#{name} passed"
          message = Exception.message(exception(result.failure_reason))
          assert message =~ shown
          assert message =~ @nudge
        end
      end
    end
  end

  describe "in forensics" do
    defp analyze(name) do
      Forensics.analyze(events: [%Ticked{}], model: model(name, :every))
    end

    test "a truthy return passes" do
      assert {:ok, _} = analyze(:ok)
    end

    test "false fails as a check failure" do
      assert {:error, violation} = analyze(:false_return)

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :false_return}} =
               violation.failure_reason

      assert Exception.message(exception(violation.failure_reason)) =~
               "check `false_return` returned `false`;"
    end

    test "nil fails with the message of item 4" do
      assert {:error, violation} = analyze(:nil_return)
      assert Exception.message(exception(violation.failure_reason)) == @nil_message
    end

    test "{:fail, text} fails with that text" do
      assert {:error, violation} = analyze(:fail_text)
      assert %CheckFailed{message: "net below fees"} = exception(violation.failure_reason)
    end
  end

  describe "in the load-test worker" do
    defp run_worker(name) do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: model(name, :every),
          target: %PropertyDamage.Target{adapter: TickAdapter, config: %{}, name: "t", index: 0},
          metrics: metrics,
          think_time_range: {0, 0},
          check_mode: :record
        )

      {:ok, stats} = Worker.execute_sequence(worker)
      Process.sleep(20)
      snapshot = Metrics.snapshot(metrics)
      Worker.stop(worker)
      Metrics.stop(metrics)
      {stats, snapshot}
    end

    test "a truthy return passes" do
      {stats, _snapshot} = run_worker(:ok)
      assert stats.commands_run >= 1
      assert stats.check_failures == 0
    end

    test "false fails as a check failure" do
      {stats, snapshot} = run_worker(:false_return)
      assert stats.commands_run >= 1
      assert stats.check_failures == stats.commands_run
      assert snapshot.failures_by_exception[CheckFailed] == stats.commands_run
    end

    test "{:fail, exception} fails with that exception" do
      {stats, snapshot} = run_worker(:fail_exception)
      assert stats.check_failures == stats.commands_run
      assert snapshot.failures_by_exception[ArgumentError] == stats.commands_run
    end
  end
end
