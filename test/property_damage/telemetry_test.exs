defmodule PropertyDamage.TelemetryTest do
  # async: false is required: this test attaches GLOBAL :telemetry handlers for
  # event names (e.g. [:property_damage, :sequence, :start]) that other tests
  # also emit via PropertyDamage.run. Under async, a concurrent run's event can
  # satisfy a name-only assert_receive here, so assertions on its metadata
  # (e.g. run_number) flake. Running sync removes the cross-test interference.
  use ExUnit.Case, async: false

  alias PropertyDamage.Telemetry
  alias PropertyDamage.Telemetry.{Collector, Dashboard}

  # Module-level handler to avoid telemetry warnings about anonymous functions
  defmodule TestHandler do
    def handle_event(event, measurements, metadata, %{pid: pid}) do
      send(pid, {:telemetry_event, event, measurements, metadata})
    end
  end

  describe "Telemetry event emission" do
    setup do
      # Attach a test handler to capture events
      handler_id = "test_handler_#{inspect(self())}"

      :telemetry.attach_many(
        handler_id,
        [
          [:property_damage, :run, :start],
          [:property_damage, :run, :stop],
          [:property_damage, :sequence, :start],
          [:property_damage, :sequence, :stop],
          [:property_damage, :command, :start],
          [:property_damage, :command, :stop]
        ],
        &TestHandler.handle_event/4,
        %{pid: self()}
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "run_start emits telemetry event" do
      Telemetry.run_start(%{model: TestModel, adapter: TestAdapter})

      assert_receive {:telemetry_event, [:property_damage, :run, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.model == TestModel
      assert metadata.adapter == TestAdapter
    end

    test "run_stop emits telemetry event with duration" do
      start_time = System.system_time()
      Process.sleep(10)

      Telemetry.run_stop(start_time, %{result: :ok, runs_completed: 10})

      assert_receive {:telemetry_event, [:property_damage, :run, :stop], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.result == :ok
      assert metadata.runs_completed == 10
    end

    test "sequence_start emits telemetry event" do
      Telemetry.sequence_start(%{run_number: 5, command_count: 10, branching: false})

      assert_receive {:telemetry_event, [:property_damage, :sequence, :start], measurements,
                      metadata}

      assert is_integer(measurements.system_time)
      assert metadata.run_number == 5
      assert metadata.command_count == 10
    end

    test "command_start and command_stop emit telemetry events" do
      Telemetry.command_start(%{command: CreateUser, index: 0})
      assert_receive {:telemetry_event, [:property_damage, :command, :start], _, metadata}
      assert metadata.command == CreateUser

      start_time = System.system_time()
      Process.sleep(5)
      Telemetry.command_stop(start_time, %{command: CreateUser, success: true})

      assert_receive {:telemetry_event, [:property_damage, :command, :stop], measurements,
                      metadata}

      assert measurements.duration > 0
      assert metadata.success == true
    end
  end

  describe "Collector" do
    setup do
      {:ok, pid} = Collector.start_link(name: nil)
      %{collector: pid}
    end

    test "initial state has zero counters", %{collector: pid} do
      state = Collector.get_state(pid)

      assert state.runs == 0
      assert state.runs_completed == 0
      assert state.runs_failed == 0
      assert state.commands_executed == 0
    end

    test "subscribe receives updates", %{collector: pid} do
      Collector.subscribe(pid)

      # Simulate a run start event
      send(
        pid,
        {:telemetry_event, [:property_damage, :run, :start], %{system_time: 0},
         %{
           model: TestModel,
           adapter: TestAdapter,
           max_runs: 10,
           max_commands: 5,
           seed: 12_345
         }}
      )

      assert_receive {:telemetry_update, :run_start, _, state}
      assert state.runs == 1
      assert state.current_run != nil
      assert state.current_run.model == TestModel
    end

    test "tracks run completion", %{collector: pid} do
      Collector.subscribe(pid)

      # Start a run
      send(
        pid,
        {:telemetry_event, [:property_damage, :run, :start], %{system_time: 0},
         %{
           model: TestModel,
           adapter: TestAdapter,
           max_runs: 10,
           max_commands: 5,
           seed: 12_345
         }}
      )

      assert_receive {:telemetry_update, :run_start, _, _}

      # Complete the run
      send(
        pid,
        {:telemetry_event, [:property_damage, :run, :stop], %{duration: 1_000_000},
         %{
           result: :ok,
           runs_completed: 10
         }}
      )

      assert_receive {:telemetry_update, :run_stop, _, state}
      assert state.runs_completed == 1
      assert state.current_run == nil
    end

    test "tracks command statistics", %{collector: pid} do
      Collector.subscribe(pid)

      # Execute a command
      send(
        pid,
        {:telemetry_event, [:property_damage, :command, :stop], %{duration: 5_000_000},
         %{
           command: CreateUser,
           success: true,
           events_count: 1
         }}
      )

      assert_receive {:telemetry_update, :command_stop, _, state}
      assert state.commands_executed == 1
      assert Map.has_key?(state.command_stats, CreateUser)
      assert state.command_stats[CreateUser].count == 1
    end

    test "reset clears all counters", %{collector: pid} do
      Collector.subscribe(pid)

      # Add some data
      send(
        pid,
        {:telemetry_event, [:property_damage, :run, :start], %{system_time: 0},
         %{
           model: TestModel,
           adapter: TestAdapter,
           max_runs: 10,
           max_commands: 5,
           seed: 12_345
         }}
      )

      assert_receive {:telemetry_update, :run_start, _, _}

      # Reset
      Collector.reset(pid)

      assert_receive {:telemetry_update, :reset, _, state}
      assert state.runs == 0
      assert state.current_run == nil
    end
  end

  describe "Dashboard" do
    test "initial_assigns returns expected structure" do
      # Start a collector first
      {:ok, _pid} = Collector.start_link()

      assigns = Dashboard.initial_assigns()

      assert Keyword.has_key?(assigns, :page_title)
      assert Keyword.has_key?(assigns, :state)
      assert Keyword.has_key?(assigns, :view_mode)
    end

    test "render returns HTML string" do
      assigns = %{
        state: %{
          runs: 10,
          runs_completed: 8,
          runs_failed: 2,
          commands_executed: 100,
          checks_passed: 50,
          checks_failed: 5,
          shrink_iterations: 3,
          total_command_time_ms: 5000,
          current_run: nil,
          recent_events: [],
          command_stats: %{},
          check_stats: %{}
        },
        view_mode: :overview
      }

      html = Dashboard.render(assigns)

      assert is_binary(html)
      assert html =~ "pd-dashboard"
      assert html =~ "10"
      assert html =~ "8 passed"
      assert html =~ "2 failed"
    end

    test "css returns valid CSS" do
      css = Dashboard.css()

      assert is_binary(css)
      assert css =~ ".pd-dashboard"
      assert css =~ ".pd-card"
      assert css =~ ".pd-success"
    end
  end

  describe "Integration with PropertyDamage.run/1" do
    setup do
      {:ok, pid} = Collector.start_link(name: nil)
      Collector.subscribe(pid)
      %{collector: pid}
    end

    test "run emits telemetry events", %{collector: _pid} do
      # Run a simple test
      alias PropertyDamage.Test.{ExecutorModel, SimpleAdapter}

      PropertyDamage.run(
        model: ExecutorModel,
        adapter: SimpleAdapter,
        max_runs: 2,
        max_commands: 3,
        validate: false
      )

      # Should receive run start
      assert_receive {:telemetry_update, :run_start, _, _}, 1000

      # Should receive sequence events
      assert_receive {:telemetry_update, :sequence_start, _, _}, 1000
    end
  end

  describe "span/1 exception routing" do
    test "emits an exception event matching the span's event_type, not :run" do
      handler_id = "span_exc_handler_#{inspect(self())}"

      :telemetry.attach_many(
        handler_id,
        [
          [:property_damage, :command, :exception],
          [:property_damage, :run, :exception]
        ],
        &TestHandler.handle_event/4,
        %{pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_raise RuntimeError, fn ->
        Telemetry.span(:command, %{command: :Foo}, fn -> raise "boom" end)
      end

      assert_receive {:telemetry_event, [:property_damage, :command, :exception], _m, _meta}
      refute_received {:telemetry_event, [:property_damage, :run, :exception], _m2, _meta2}
    end
  end
end
