defmodule PropertyDamageTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{RunResult, RunUpdate}

  # Module-function telemetry handler (avoids the local-function performance
  # warning telemetry logs for anonymous handlers).
  def forward_telemetry(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  alias PropertyDamage.Test.{
    ExecutorModel,
    FailingModel,
    SimpleAdapter
  }

  describe "module" do
    test "defines moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(PropertyDamage)

      assert moduledoc =~ "stateful property-based testing"
    end
  end

  describe "run/1 validation" do
    test "requires model option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :model option not found/, fn ->
        PropertyDamage.run(adapter: SimpleAdapter)
      end
    end

    test "requires adapter option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :adapter option not found/, fn ->
        PropertyDamage.run(model: ExecutorModel)
      end
    end
  end

  describe "run/1 success" do
    test "returns {:ok, stats} on success" do
      result =
        PropertyDamage.run(
          model: ExecutorModel,
          adapter: SimpleAdapter,
          max_runs: 3,
          max_commands: 5,
          validate: false
        )

      assert {:ok, stats} = result
      assert stats.runs == 3
      assert stats.total_commands > 0
      assert is_integer(stats.seed)
    end

    test "respects seed for reproducibility" do
      opts = [
        model: ExecutorModel,
        adapter: SimpleAdapter,
        max_runs: 3,
        max_commands: 5,
        seed: 12_345,
        validate: false
      ]

      {:ok, stats1} = PropertyDamage.run(opts)
      {:ok, stats2} = PropertyDamage.run(opts)

      assert stats1.seed == stats2.seed
      assert stats1.seed == 12_345
    end
  end

  # An injector whose setup/1 raises. It runs in the run (test) process, so it
  # reports the run's EventQueue pid to that process's mailbox before blowing up,
  # letting the test check whether the queue leaked.
  defmodule LeakProbeInjector do
    use PropertyDamage.Adapter.Injector

    @emits []

    @impl true
    def setup(%{event_queue: event_queue}) do
      send(self(), {:leaked_event_queue, event_queue})
      raise "injector setup boom"
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def to_event(_payload), do: :skip
  end

  # A command + always-failing assertion, so run 0 always finds a failure and
  # `handle_failure` (with its reproduction re-execution) is reached.
  defmodule AlwaysFailCmd do
    use PropertyDamage.Command
    defstruct []
    @impl true
    def generator(_overrides), do: StreamData.constant(%{})
  end

  defmodule AlwaysFailState do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
  end

  defmodule AlwaysFailAssertion do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state

    @trigger every: 1
    def always_fail(_state, _cmd_or_event), do: PropertyDamage.fail!("always fails")
  end

  defmodule AlwaysFailModel do
    @behaviour PropertyDamage.Model
    def commands, do: [AlwaysFailCmd]
    def command_sequence_projection, do: AlwaysFailState
    def assertion_projections, do: [AlwaysFailAssertion]
  end

  # Setup succeeds on the exploration run and fails on the second call, which is
  # the reproduction re-execution inside `handle_failure`.
  defmodule SecondSetupFailsAdapter do
    use PropertyDamage.Adapter

    def setup(%{setup_counter: ref}) do
      if :atomics.add_get(ref, 1, 1) >= 2, do: {:error, :setup_failed}, else: {:ok, %{}}
    end

    def teardown(_context), do: :ok
    def execute(_command, _context, _runtime), do: {:ok, []}
  end

  describe "run/1 error boundaries" do
    @tag :capture_log
    test "an injector whose setup raises does not leak the EventQueue" do
      assert_raise RuntimeError, ~r/injector setup boom/, fn ->
        PropertyDamage.run(
          model: ExecutorModel,
          adapter: SimpleAdapter,
          injector_adapters: [LeakProbeInjector],
          max_runs: 1,
          max_commands: 3,
          validate: false
        )
      end

      assert_received {:leaked_event_queue, event_queue}
      refute Process.alive?(event_queue)
    end

    test "adapter setup failure surfaces as an error, not a MatchError crash" do
      result =
        PropertyDamage.run(
          model: ExecutorModel,
          adapter: PropertyDamage.Test.FailingAdapter,
          adapter_config: %{fail_setup: true},
          max_runs: 1,
          max_commands: 3,
          validate: false
        )

      assert {:error, info} = result
      assert info.adapter_setup_failed == :setup_failed
    end

    @tag :capture_log
    test "reproduction re-execution setup failure falls back to the original failure, not a MatchError" do
      ref = :atomics.new(1, [])

      result =
        PropertyDamage.run(
          model: AlwaysFailModel,
          adapter: SecondSetupFailsAdapter,
          adapter_config: %{setup_counter: ref},
          max_runs: 1,
          max_commands: 3,
          shrink: false,
          validate: false
        )

      assert {:error, %PropertyDamage.FailureReport{} = report} = result
      assert report.failure_reason != nil
    end
  end

  describe "execute/2 error boundaries" do
    @tag :capture_log
    test "an injector whose setup raises does not leak the EventQueue" do
      assert_raise RuntimeError, ~r/injector setup boom/, fn ->
        PropertyDamage.execute([],
          adapter: SimpleAdapter,
          injector_adapters: [LeakProbeInjector]
        )
      end

      assert_received {:leaked_event_queue, event_queue}
      refute Process.alive?(event_queue)
    end
  end

  describe "run/1 with lifecycle callbacks" do
    defmodule LifecycleModel do
      @behaviour PropertyDamage.Model

      alias PropertyDamage.Test.Commands.CreateItem
      alias PropertyDamage.Test.Projections.ModelState

      @impl true
      def commands, do: [CreateItem]

      @impl true
      def command_sequence_projection, do: ModelState

      @impl true
      def assertion_projections, do: []

      # Every callback echoes the exact map it received back to the test pid,
      # which lives in adapter_config (guaranteed present on every path).
      @impl true
      def setup_once(config) do
        send(config.adapter_config.test_pid, {:lifecycle, :setup_once, config})
        :ok
      end

      @impl true
      def setup_each(config) do
        send(config.adapter_config.test_pid, {:lifecycle, :setup_each, config})
        :ok
      end

      @impl true
      def teardown_each(config) do
        send(config.adapter_config.test_pid, {:lifecycle, :teardown_each, config})
        :ok
      end

      @impl true
      def teardown_once(config) do
        send(config.adapter_config.test_pid, {:lifecycle, :teardown_once, config})
        :ok
      end
    end

    test "setup_once and teardown_once receive %{adapter_config: ...} on the run path" do
      pid = self()

      PropertyDamage.run(
        model: LifecycleModel,
        adapter: SimpleAdapter,
        max_runs: 1,
        max_commands: 2,
        validate: false,
        adapter_config: %{test_pid: pid}
      )

      assert_received {:lifecycle, :setup_once, setup_config}
      assert setup_config == %{adapter_config: %{test_pid: pid}}

      assert_received {:lifecycle, :teardown_once, teardown_config}
      assert teardown_config == %{adapter_config: %{test_pid: pid}}
    end

    test "setup_each and teardown_each receive adapter_config + run_number on the run path" do
      pid = self()

      PropertyDamage.run(
        model: LifecycleModel,
        adapter: SimpleAdapter,
        max_runs: 3,
        max_commands: 2,
        validate: false,
        adapter_config: %{test_pid: pid}
      )

      for n <- 0..2 do
        assert_received {:lifecycle, :setup_each,
                         %{adapter_config: %{test_pid: ^pid}, run_number: ^n} = setup_config}

        assert map_size(setup_config) == 2

        assert_received {:lifecycle, :teardown_each,
                         %{adapter_config: %{test_pid: ^pid}, run_number: ^n} = teardown_config}

        assert map_size(teardown_config) == 2
        refute Map.has_key?(teardown_config, :replay)
      end
    end
  end

  describe "run/1 failure handling" do
    # FailingModel's invariant fails when the CUMULATIVE quantity exceeds
    # 100, so a failure is certain well within these run bounds. The seed is
    # fixed: failure is mandatory, not opportunistic.
    test "returns {:error, failure_report} on failure" do
      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          seed: 42,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: false
        )

      assert {:error, %PropertyDamage.FailureReport{} = report} = result
      assert PropertyDamage.FailureReport.check_name(report) == :quantity_limit
      assert is_integer(report.failed_at_index)

      # With shrink: false the shrunk sequence is the original
      assert PropertyDamage.FailureReport.shrunk_sequence(report) == report.original_sequence
    end

    test "invokes on_failure callback" do
      test_pid = self()

      on_failure = fn report ->
        send(test_pid, {:failure_report, report})
      end

      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          seed: 42,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: false,
          on_failure: on_failure
        )

      assert {:error, _report} = result
      assert_received {:failure_report, report}
      assert %PropertyDamage.FailureReport{} = report
      assert PropertyDamage.FailureReport.check_name(report) == :quantity_limit
    end
  end

  describe "run/1 shrinking" do
    test "shrinks failing sequences when shrink: true" do
      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          seed: 42,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: true
        )

      assert {:error, report} = result

      original = PropertyDamage.Sequence.to_list(report.original_sequence)

      shrunk =
        PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))

      assert length(shrunk) <= length(original)

      # Failure equivalence: the shrunk sequence must still violate the
      # invariant (cumulative quantity above the limit)
      shrunk_total = shrunk |> Enum.map(& &1.quantity) |> Enum.sum()
      assert shrunk_total > 100
    end
  end

  describe "run/1 verbose mode" do
    test "prints progress when verbose: true" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PropertyDamage.run(
            model: ExecutorModel,
            adapter: SimpleAdapter,
            max_runs: 2,
            max_commands: 3,
            validate: true,
            verbose: true
          )
        end)

      assert output =~ "PropertyDamage Configuration Summary"
      assert output =~ "Run 1/2"
      assert output =~ "Run 2/2"
    end
  end

  describe "run/1 progress reporting" do
    test "on_progress receives ordered start/run updates and a terminal result" do
      parent = self()

      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: ExecutorModel,
                 adapter: SimpleAdapter,
                 max_runs: 2,
                 max_commands: 3,
                 validate: false,
                 on_progress: fn p -> send(parent, {:progress, p}) end
               )

      # Inline, ordered fan-out: messages arrive in emission order.
      assert_receive {:progress, %Progress{data: %RunUpdate{phase: :start, total_runs: 2}}}

      assert_receive {:progress,
                      %Progress{data: %RunUpdate{phase: :run, run_number: 1, total_runs: 2}}}

      assert_receive {:progress,
                      %Progress{data: %RunUpdate{phase: :run, run_number: 2, total_runs: 2}}}

      assert_receive {:progress, %Progress{data: %RunResult{outcome: :ok, runs_completed: 2}}}
    end

    test "on_progress delivers a terminal error result on failure" do
      parent = self()

      assert {:error, _report} =
               PropertyDamage.run(
                 model: FailingModel,
                 adapter: SimpleAdapter,
                 seed: 42,
                 max_runs: 100,
                 max_commands: 50,
                 validate: false,
                 shrink: false,
                 on_progress: fn p -> send(parent, {:progress, p}) end
               )

      assert_receive {:progress, %Progress{data: %RunResult{outcome: :error, failure: report}}}
      assert match?(%PropertyDamage.FailureReport{}, report)
    end

    test "emits coarse test_run progress and result telemetry events" do
      parent = self()
      handler_id = "pd-progress-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:property_damage, :test_run, :progress], [:property_damage, :test_run, :result]],
        &__MODULE__.forward_telemetry/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      PropertyDamage.run(
        model: ExecutorModel,
        adapter: SimpleAdapter,
        max_runs: 1,
        max_commands: 2,
        validate: false
      )

      assert_receive {:telemetry, [:property_damage, :test_run, :progress], _m,
                      %{data: %RunUpdate{}}}

      assert_receive {:telemetry, [:property_damage, :test_run, :result], _m,
                      %{data: %RunResult{outcome: :ok}}}
    end
  end
end
