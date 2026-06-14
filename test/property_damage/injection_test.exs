defmodule PropertyDamage.InjectionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, Ref}
  alias PropertyDamage.EventLog.Entry

  # Test events
  defmodule ResourceCreated do
    defstruct [:resource_id, :name]
  end

  defmodule ResourceSettled do
    defstruct [:resource_id, :status]
  end

  defmodule OtherEvent do
    defstruct [:data]
  end

  # Test command that creates a ref
  defmodule CreateResource do
    defstruct [:resource_id, :name]

    def generator(_overrides \\ %{}), do: StreamData.constant(%{name: "resource"})
    def creates_ref, do: :resource_id
  end

  # Test command that doesn't create a ref
  defmodule SimpleCommand do
    defstruct [:data]

    def generator(_overrides \\ %{}), do: StreamData.constant(%{data: "test"})
  end

  # Test projection that tracks resources
  defmodule ResourceProjection do
    def init, do: %{resources: %{}, events: []}

    def apply(state, %ResourceCreated{resource_id: id, name: name}) do
      %{state | resources: Map.put(state.resources, id, %{name: name, status: :created})}
    end

    def apply(state, %ResourceSettled{resource_id: id, status: status}) do
      resources =
        Map.update(state.resources, id, %{status: status}, fn r ->
          Map.put(r, :status, status)
        end)

      %{state | resources: resources}
    end

    def apply(state, event) do
      %{state | events: [event | state.events]}
    end
  end

  # Test model
  defmodule TestModel do
    def command_sequence_projection, do: ResourceProjection
    def assertion_projections, do: []
    def commands, do: [CreateResource, SimpleCommand]
    def simulate(_cmd, _state), do: []
  end

  # Adapter that uses injection
  defmodule InjectingAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config) do
      {:ok, %{}}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CreateResource{resource_id: _ref, name: name}, ctx) do
      # Generate a real ID
      real_id = "resource_#{:erlang.unique_integer([:positive])}"

      # Inject the created event immediately
      ctx.inject.(%ResourceCreated{resource_id: real_id, name: name})

      # Simulate polling/settling and return settlement event
      {:ok, [%ResourceSettled{resource_id: real_id, status: :approved}]}
    end

    def execute(%SimpleCommand{data: data}, _ctx) do
      {:ok, [%OtherEvent{data: data}]}
    end
  end

  # Adapter that doesn't use injection (backward compatibility)
  defmodule NonInjectingAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CreateResource{name: name}, _ctx) do
      real_id = "resource_#{:erlang.unique_integer([:positive])}"

      # Returns all events at end - doesn't use ctx.inject
      {:ok,
       [
         %ResourceCreated{resource_id: real_id, name: name},
         %ResourceSettled{resource_id: real_id, status: :approved}
       ]}
    end

    def execute(%SimpleCommand{data: data}, _ctx) do
      {:ok, [%OtherEvent{data: data}]}
    end
  end

  # Adapter that injects multiple events
  defmodule MultiInjectAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:ok, %{}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CreateResource{name: name}, ctx) do
      real_id = "resource_#{:erlang.unique_integer([:positive])}"

      # Inject multiple events during execution
      ctx.inject.(%ResourceCreated{resource_id: real_id, name: name})
      ctx.inject.(%ResourceSettled{resource_id: real_id, status: :pending})

      # Return final event
      {:ok, [%ResourceSettled{resource_id: real_id, status: :approved}]}
    end

    def execute(%SimpleCommand{data: data}, _ctx) do
      {:ok, [%OtherEvent{data: data}]}
    end
  end

  describe "mid-execution event injection" do
    test "injected events update projections immediately" do
      ref = Ref.symbolic(label: "resource")
      command = %CreateResource{resource_id: ref, name: "test"}

      {:ok, result} = Executor.run([command], TestModel, InjectingAdapter)

      assert result.success

      # Projections should have the resource
      projection_state = result.projections[ResourceProjection]
      assert map_size(projection_state.resources) == 1

      # Get the actual resource ID
      [resource_id] = Map.keys(projection_state.resources)
      resource = projection_state.resources[resource_id]

      # Final status should be approved (from returned event)
      assert resource.status == :approved
    end

    test "injected events are recorded with source :injected" do
      ref = Ref.symbolic(label: "resource")
      command = %CreateResource{resource_id: ref, name: "test"}

      {:ok, result} = Executor.run([command], TestModel, InjectingAdapter)

      # Should have 2 events: 1 injected + 1 returned
      assert length(result.event_log) == 2

      # Find the injected event
      injected_entries = Enum.filter(result.event_log, &Entry.injected?/1)
      assert length(injected_entries) == 1

      [injected] = injected_entries
      assert injected.source == :injected
      assert match?(%ResourceCreated{}, injected.event)
      assert injected.command_index == 0

      # Find the command event
      command_entries = Enum.filter(result.event_log, &Entry.command?/1)
      assert length(command_entries) == 1

      [cmd_entry] = command_entries
      assert cmd_entry.source == :command
      assert match?(%ResourceSettled{}, cmd_entry.event)
    end

    test "refs are bound from injected events" do
      ref = Ref.symbolic(label: "resource")
      command = %CreateResource{resource_id: ref, name: "test"}

      {:ok, result} = Executor.run([command], TestModel, InjectingAdapter)

      # The ref should be bound to the actual resource ID from the injected event
      assert Map.has_key?(result.refs, ref.ref)
      bound_value = result.refs[ref.ref]
      assert String.starts_with?(bound_value, "resource_")
    end

    test "multiple injections work correctly" do
      ref = Ref.symbolic(label: "resource")
      command = %CreateResource{resource_id: ref, name: "test"}

      {:ok, result} = Executor.run([command], TestModel, MultiInjectAdapter)

      # Should have 3 events: 2 injected + 1 returned
      assert length(result.event_log) == 3

      injected_entries = Enum.filter(result.event_log, &Entry.injected?/1)
      assert length(injected_entries) == 2

      command_entries = Enum.filter(result.event_log, &Entry.command?/1)
      assert length(command_entries) == 1
    end

    test "backward compatibility - adapters not using inject work unchanged" do
      ref = Ref.symbolic(label: "resource")
      command = %CreateResource{resource_id: ref, name: "test"}

      {:ok, result} = Executor.run([command], TestModel, NonInjectingAdapter)

      assert result.success

      # Should have 2 events, both as command events
      assert length(result.event_log) == 2

      command_entries = Enum.filter(result.event_log, &Entry.command?/1)
      assert length(command_entries) == 2

      injected_entries = Enum.filter(result.event_log, &Entry.injected?/1)
      assert injected_entries == []

      # Refs should still be bound from returned events
      assert Map.has_key?(result.refs, ref.ref)
    end

    test "injected events appear before returned events in log" do
      ref = Ref.symbolic(label: "resource")
      command = %CreateResource{resource_id: ref, name: "test"}

      {:ok, result} = Executor.run([command], TestModel, InjectingAdapter)

      # Event log is already reversed, so check order
      # First entry should be the returned event (last to be added)
      # Second entry should be the injected event (first to be added)
      [first, second] = result.event_log

      # The injected event should come BEFORE the returned event in chronological order
      # After reversal in finalize_result, it should appear first
      assert Entry.injected?(first)
      assert Entry.command?(second)
    end
  end

  describe "Entry.from_injected/3" do
    test "creates entry with correct source" do
      event = %ResourceCreated{resource_id: "123", name: "test"}
      entry = Entry.from_injected(event, 5)

      assert entry.source == :injected
      assert entry.command_index == 5
      assert entry.event == event
      assert entry.injector_adapter == nil
      assert entry.nemesis_module == nil
    end

    test "supports branch_id option" do
      event = %ResourceCreated{resource_id: "123", name: "test"}
      entry = Entry.from_injected(event, 2, branch_id: 1)

      assert entry.branch_id == 1
    end

    test "supports timestamp option" do
      event = %ResourceCreated{resource_id: "123", name: "test"}
      entry = Entry.from_injected(event, 0, timestamp: 12345)

      assert entry.timestamp == 12345
    end
  end

  describe "Entry.injected?/1" do
    test "returns true for injected entries" do
      entry = Entry.from_injected(%ResourceCreated{resource_id: "1", name: "x"}, 0)
      assert Entry.injected?(entry)
    end

    test "returns false for command entries" do
      entry = Entry.from_command(%ResourceCreated{resource_id: "1", name: "x"}, 0)
      refute Entry.injected?(entry)
    end

    test "returns false for other source types" do
      entry = Entry.from_mock(%ResourceCreated{resource_id: "1", name: "x"}, 0)
      refute Entry.injected?(entry)
    end
  end
end
