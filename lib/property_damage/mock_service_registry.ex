defmodule PropertyDamage.MockServiceRegistry do
  @moduledoc """
  Registry for managing mock service adapters and their state.

  The MockServiceRegistry:
  - Manages state for all active mock adapters
  - Collects events injected by mocks
  - Notifies mocks of commands and events
  - Provides projection state to mocks for request handling

  ## Lifecycle

  1. `start_link/1` - Start the registry
  2. `register/2` - Register mock adapters
  3. During execution:
     - `notify_command/2` - Inform mocks of commands
     - `update_projections/2` - Share projection state
     - `push_event/3` - Mocks inject events
     - `flush_events/1` - Executor collects injected events
     - `notify_event/2` - Inform mocks of events
  4. `stop/1` - Stop the registry

  ## Usage

  ```elixir
  {:ok, registry} = MockServiceRegistry.start_link([])

  # Register mock adapters
  MockServiceRegistry.register(registry, PaymentMock)
  MockServiceRegistry.register(registry, EmailMock)

  # During test execution
  MockServiceRegistry.notify_command(registry, command)
  MockServiceRegistry.update_projections(registry, projections)

  # Mock calls push_event when SUT calls them
  MockServiceRegistry.push_event(registry, PaymentMock, %PaymentProcessed{})

  # Executor collects injected events
  events = MockServiceRegistry.flush_events(registry)

  # Notify mocks of events
  for event <- events do
    MockServiceRegistry.notify_event(registry, event)
  end
  ```
  """

  use GenServer

  @type t :: pid()

  @doc """
  Start the mock service registry.

  ## Options

  - `:name` - Optional name for the registry process
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stop the registry.
  """
  @spec stop(t()) :: :ok
  def stop(registry) do
    GenServer.stop(registry, :normal)
  end

  @doc """
  Register a mock adapter with the registry.

  The adapter's `init_state/0` is called to initialize its state.
  """
  @spec register(t(), module()) :: :ok
  def register(registry, adapter_module) do
    GenServer.call(registry, {:register, adapter_module})
  end

  @doc """
  Unregister a mock adapter.
  """
  @spec unregister(t(), module()) :: :ok
  def unregister(registry, adapter_module) do
    GenServer.call(registry, {:unregister, adapter_module})
  end

  @doc """
  Notify all mocks of a command being executed.

  Each mock's `on_command/2` is called with the command.
  Returns true if any mock handles this as a config command.
  """
  @spec notify_command(t(), struct()) :: {:ok, boolean()}
  def notify_command(registry, command) do
    GenServer.call(registry, {:notify_command, command})
  end

  @doc """
  Notify all mocks of an event.

  Each mock's `on_event/2` is called with the event.
  """
  @spec notify_event(t(), struct()) :: :ok
  def notify_event(registry, event) do
    GenServer.call(registry, {:notify_event, event})
  end

  @doc """
  Update the projection state available to mocks.

  Called after each command execution so mocks have current state.
  """
  @spec update_projections(t(), map()) :: :ok
  def update_projections(registry, projections) do
    GenServer.call(registry, {:update_projections, projections})
  end

  @doc """
  Push an event from a mock adapter.

  Called by mock adapters when they inject events.
  """
  @spec push_event(t(), module(), struct()) :: :ok
  def push_event(registry, adapter_module, event) do
    GenServer.call(registry, {:push_event, adapter_module, event})
  end

  @doc """
  Push multiple events from a mock adapter.
  """
  @spec push_events(t(), module(), [struct()]) :: :ok
  def push_events(registry, adapter_module, events) do
    GenServer.call(registry, {:push_events, adapter_module, events})
  end

  @doc """
  Flush all pending injected events.

  Returns events in the order they were pushed. Events are cleared
  from the registry after flushing.
  """
  @spec flush_events(t()) :: [struct()]
  def flush_events(registry) do
    GenServer.call(registry, :flush_events)
  end

  @doc """
  Get the current state for a mock adapter.

  Used by mock handlers to access their state during request handling.
  """
  @spec get_state(t(), module()) :: {:ok, map()} | {:error, :not_found}
  def get_state(registry, adapter_module) do
    GenServer.call(registry, {:get_state, adapter_module})
  end

  @doc """
  Update the state for a mock adapter.

  Used by mock handlers if they need to update state during request handling.
  """
  @spec update_state(t(), module(), map()) :: :ok
  def update_state(registry, adapter_module, new_state) do
    GenServer.call(registry, {:update_state, adapter_module, new_state})
  end

  @doc """
  Get the combined state for request handling.

  Returns mock state merged with current projections.
  """
  @spec get_handler_state(t(), module()) :: {:ok, map()} | {:error, :not_found}
  def get_handler_state(registry, adapter_module) do
    GenServer.call(registry, {:get_handler_state, adapter_module})
  end

  # ==========================================================================
  # GenServer Implementation
  # ==========================================================================

  @impl true
  def init(_opts) do
    state = %{
      adapters: %{},
      projections: %{},
      pending_events: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, adapter_module}, _from, state) do
    adapter_state = adapter_module.init_state()

    new_adapters = Map.put(state.adapters, adapter_module, adapter_state)
    {:reply, :ok, %{state | adapters: new_adapters}}
  end

  @impl true
  def handle_call({:unregister, adapter_module}, _from, state) do
    new_adapters = Map.delete(state.adapters, adapter_module)
    {:reply, :ok, %{state | adapters: new_adapters}}
  end

  @impl true
  def handle_call({:notify_command, command}, _from, state) do
    alias PropertyDamage.MockServiceAdapter

    is_mock_config = MockServiceAdapter.mock_config_command?(command)

    # Update each adapter's state via on_command
    new_adapters =
      Enum.reduce(state.adapters, %{}, fn {module, adapter_state}, acc ->
        new_adapter_state = module.on_command(command, adapter_state)
        Map.put(acc, module, new_adapter_state)
      end)

    {:reply, {:ok, is_mock_config}, %{state | adapters: new_adapters}}
  end

  @impl true
  def handle_call({:notify_event, event}, _from, state) do
    # Update each adapter's state via on_event
    new_adapters =
      Enum.reduce(state.adapters, %{}, fn {module, adapter_state}, acc ->
        new_adapter_state = module.on_event(event, adapter_state)
        Map.put(acc, module, new_adapter_state)
      end)

    {:reply, :ok, %{state | adapters: new_adapters}}
  end

  @impl true
  def handle_call({:update_projections, projections}, _from, state) do
    {:reply, :ok, %{state | projections: projections}}
  end

  @impl true
  def handle_call({:push_event, _adapter_module, event}, _from, state) do
    new_pending = state.pending_events ++ [event]
    {:reply, :ok, %{state | pending_events: new_pending}}
  end

  @impl true
  def handle_call({:push_events, _adapter_module, events}, _from, state) do
    new_pending = state.pending_events ++ events
    {:reply, :ok, %{state | pending_events: new_pending}}
  end

  @impl true
  def handle_call(:flush_events, _from, state) do
    events = state.pending_events
    {:reply, events, %{state | pending_events: []}}
  end

  @impl true
  def handle_call({:get_state, adapter_module}, _from, state) do
    case Map.fetch(state.adapters, adapter_module) do
      {:ok, adapter_state} -> {:reply, {:ok, adapter_state}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_state, adapter_module, new_adapter_state}, _from, state) do
    if Map.has_key?(state.adapters, adapter_module) do
      new_adapters = Map.put(state.adapters, adapter_module, new_adapter_state)
      {:reply, :ok, %{state | adapters: new_adapters}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_handler_state, adapter_module}, _from, state) do
    case Map.fetch(state.adapters, adapter_module) do
      {:ok, adapter_state} ->
        # Merge projections into the state for handler use
        handler_state = Map.put(adapter_state, :projections, state.projections)
        {:reply, {:ok, handler_state}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end
end
