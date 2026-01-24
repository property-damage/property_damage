defmodule PropertyDamage.ExecuteTest do
  use ExUnit.Case, async: true

  alias PropertyDamage
  alias PropertyDamage.EventQueue

  # Simple test adapter that tracks calls and returns configurable events
  defmodule TestAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%{action: :create, id: id}, _ctx) do
      {:ok, [%{type: :created, id: id}]}
    end

    def execute(%{action: :create}, _ctx) do
      {:ok, [%{type: :created, id: 1}]}
    end

    def execute(%{action: :update, id: id, value: value}, _ctx) do
      {:ok, [%{type: :updated, id: id, value: value}]}
    end

    def execute(%{action: :delete, id: id}, _ctx) do
      {:ok, [%{type: :deleted, id: id}]}
    end

    def execute(%{action: :multi_event}, _ctx) do
      {:ok, [%{type: :event_a}, %{type: :event_b}]}
    end

    def execute(%{action: :no_events}, _ctx) do
      {:ok, []}
    end

    def execute(%{action: :fail}, _ctx) do
      {:error, :intentional_failure}
    end

    def execute(%{action: :fail_with_reason, reason: reason}, _ctx) do
      {:error, reason}
    end
  end

  # Adapter that fails on setup
  defmodule FailingSetupAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:error, :setup_failed}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, _ctx), do: {:ok, []}
  end

  # Simple injector adapter for testing
  defmodule TestInjectorAdapter do
    use PropertyDamage.Adapter.Injector

    @impl true
    def setup(%{event_queue: event_queue}) do
      # Store event queue in process dictionary for testing
      Process.put(:test_injector_event_queue, event_queue)
      {:ok, %{}}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def to_event(payload), do: {:ok, payload}

    # Helper to inject an event from tests
    def inject_event(event) do
      case Process.get(:test_injector_event_queue) do
        nil -> :error
        queue -> EventQueue.push(queue, __MODULE__, event)
      end
    end
  end

  describe "execute/2 basic functionality" do
    test "executes a single command and returns event log" do
      commands = [%{action: :create}]

      {:ok, events} = PropertyDamage.execute(commands, adapter: TestAdapter)

      assert length(events) == 1
      assert hd(events).event == %{type: :created, id: 1}
      assert hd(events).source == :command
      assert hd(events).command_index == 0
    end

    test "executes multiple commands in sequence" do
      commands = [
        %{action: :create, id: 1},
        %{action: :update, id: 1, value: "updated"},
        %{action: :delete, id: 1}
      ]

      {:ok, events} = PropertyDamage.execute(commands, adapter: TestAdapter)

      assert length(events) == 3

      [create, update, delete] = events

      assert create.event == %{type: :created, id: 1}
      assert create.command_index == 0

      assert update.event == %{type: :updated, id: 1, value: "updated"}
      assert update.command_index == 1

      assert delete.event == %{type: :deleted, id: 1}
      assert delete.command_index == 2
    end

    test "handles commands that return multiple events" do
      commands = [%{action: :multi_event}]

      {:ok, events} = PropertyDamage.execute(commands, adapter: TestAdapter)

      assert length(events) == 2
      assert Enum.at(events, 0).event == %{type: :event_a}
      assert Enum.at(events, 1).event == %{type: :event_b}
    end

    test "handles commands that return no events" do
      commands = [%{action: :no_events}]

      {:ok, events} = PropertyDamage.execute(commands, adapter: TestAdapter)

      assert events == []
    end

    test "returns empty list for empty command sequence" do
      {:ok, events} = PropertyDamage.execute([], adapter: TestAdapter)

      assert events == []
    end
  end

  describe "execute/2 error handling" do
    test "returns error when adapter execution fails" do
      commands = [%{action: :fail}]

      assert {:error, {:adapter_error, :intentional_failure, []}} =
               PropertyDamage.execute(commands, adapter: TestAdapter)
    end

    test "returns error with partial events when failure occurs mid-sequence" do
      commands = [
        %{action: :create, id: 1},
        %{action: :fail},
        %{action: :create, id: 2}
      ]

      assert {:error, {:adapter_error, :intentional_failure, partial_events}} =
               PropertyDamage.execute(commands, adapter: TestAdapter)

      # Should have events from the first successful command
      assert length(partial_events) == 1
      assert hd(partial_events).event == %{type: :created, id: 1}
    end

    test "returns error when adapter setup fails" do
      commands = [%{action: :create}]

      assert {:error, {:adapter_setup_failed, :setup_failed}} =
               PropertyDamage.execute(commands, adapter: FailingSetupAdapter)
    end

    test "includes custom error reason from adapter" do
      commands = [%{action: :fail_with_reason, reason: {:custom_error, "details"}}]

      assert {:error, {:adapter_error, {:custom_error, "details"}, []}} =
               PropertyDamage.execute(commands, adapter: TestAdapter)
    end
  end

  describe "execute/2 with adapter_config" do
    test "passes adapter_config to adapter setup" do
      defmodule ConfigTrackingAdapter do
        use PropertyDamage.Adapter

        @impl true
        def setup(config) do
          send(self(), {:adapter_setup, config})
          {:ok, config}
        end

        @impl true
        def teardown(_ctx), do: :ok

        @impl true
        def execute(_cmd, _ctx), do: {:ok, []}
      end

      config = %{base_url: "http://example.com", api_key: "secret"}

      {:ok, _} =
        PropertyDamage.execute([], adapter: ConfigTrackingAdapter, adapter_config: config)

      assert_received {:adapter_setup, ^config}
    end
  end

  describe "execute/2 with injector adapters" do
    test "collects events from injector adapters" do
      # Create an adapter that triggers injector events
      defmodule InjectingAdapter do
        use PropertyDamage.Adapter

        @impl true
        def setup(config), do: {:ok, config}

        @impl true
        def teardown(_ctx), do: :ok

        @impl true
        def execute(%{action: :trigger_webhook}, ctx) do
          # Simulate the SUT calling a webhook that our injector receives
          # In real tests, this would happen asynchronously via actual HTTP
          event_queue = ctx[:event_queue]

          if event_queue do
            EventQueue.push(event_queue, TestInjectorAdapter, %{
              type: :webhook_received,
              payload: "test_data"
            })
          end

          {:ok, [%{type: :command_executed}]}
        end
      end

      commands = [%{action: :trigger_webhook}]

      {:ok, events} =
        PropertyDamage.execute(commands,
          adapter: InjectingAdapter,
          injector_adapters: [TestInjectorAdapter],
          adapter_config: %{}
        )

      # Should have both command event and injector event
      assert length(events) == 2

      command_event = Enum.find(events, &(&1.source == :command))
      injector_event = Enum.find(events, &(&1.source == :injector))

      assert command_event.event == %{type: :command_executed}
      assert injector_event.event == %{type: :webhook_received, payload: "test_data"}
      assert injector_event.injector_adapter == TestInjectorAdapter
    end
  end

  describe "execute/2 options validation" do
    test "requires adapter option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :adapter option/, fn ->
        PropertyDamage.execute([], [])
      end
    end

    test "validates adapter is an atom" do
      assert_raise NimbleOptions.ValidationError, ~r/expected a module/, fn ->
        PropertyDamage.execute([], adapter: "not_an_atom")
      end
    end

    test "accepts optional injector_adapters" do
      {:ok, _} =
        PropertyDamage.execute([],
          adapter: TestAdapter,
          injector_adapters: [TestInjectorAdapter]
        )
    end

    test "accepts optional refs" do
      {:ok, _} =
        PropertyDamage.execute([],
          adapter: TestAdapter,
          refs: %{some_ref: "value"}
        )
    end
  end
end
