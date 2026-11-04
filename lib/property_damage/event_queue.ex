defmodule PropertyDamage.EventQueue do
  @moduledoc """
  Shared event queue for injector adapters.

  The EventQueue is an Agent-based queue that collects events pushed by
  injector adapters (webhooks, callbacks, etc.) and makes them available
  to the executor for processing.

  ## Usage Flow

  1. Framework starts the queue via `start_link/0`
  2. Injector adapters receive the queue reference in their config
  3. When events arrive (webhooks, callbacks), adapters push them via `push/3`
  4. After each command execution, the executor drains pending events via `drain/1`
  5. Framework stops the queue via `stop/1` after the run completes

  ## Event Entries

  An entry is a map. Its keys depend on how the event arrived.

  An entry pushed by `push/3` (an injector adapter) contains:

  - `event` - The event struct
  - `adapter_module` - The injector adapter that received it
  - `timestamp` - Monotonic time when the event was pushed

  An entry pushed by `push_from_poller/5` (a resource poller) has no
  `adapter_module`. It contains:

  - `event` - The event struct
  - `source` - Always `:resource_poller`
  - `poller_id` - Reference identifying the poller instance
  - `command_index` - Index of the command that started the poller
  - `branch_id` - The branch identifier, or `nil`
  - `timestamp` - Monotonic time when the event was pushed

  ## Example

      # In test setup
      {:ok, queue} = EventQueue.start_link()

      # In injector adapter callback
      EventQueue.push(queue, __MODULE__, %PaymentConfirmed{...})

      # In executor loop
      pending_events = EventQueue.drain(queue)

      # In test teardown
      EventQueue.stop(queue)
  """

  @typedoc """
  Event entry with metadata.

  `push/3` builds the injector shape and `push_from_poller/5` builds the
  poller shape. See "Event Entries" for each key.
  """
  @type entry :: injector_entry() | poller_entry()

  @typedoc "An entry pushed by an injector adapter through `push/3`."
  @type injector_entry :: %{
          event: struct(),
          adapter_module: module(),
          timestamp: integer()
        }

  @typedoc "An entry pushed by a resource poller through `push_from_poller/5`."
  @type poller_entry :: %{
          event: struct(),
          source: :resource_poller,
          poller_id: reference(),
          command_index: non_neg_integer(),
          branch_id: non_neg_integer() | nil,
          timestamp: integer()
        }

  @doc """
  Start a new event queue.

  ## Returns

  - `{:ok, queue}` - Queue started successfully
  - `{:error, reason}` - Failed to start

  ## Example

      {:ok, queue} = EventQueue.start_link()
  """
  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link do
    Agent.start_link(fn -> [] end)
  end

  @doc """
  Start a new event queue with options.

  ## Options

  Accepts standard Agent options like `:name`.

  ## Example

      {:ok, queue} = EventQueue.start_link(name: :my_event_queue)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    Agent.start_link(fn -> [] end, opts)
  end

  @doc """
  Stop the event queue.

  ## Example

      :ok = EventQueue.stop(queue)
  """
  @spec stop(pid()) :: :ok
  def stop(queue) do
    Agent.stop(queue)
  end

  @doc """
  Push an event from an injector adapter.

  Events are timestamped automatically with monotonic time.

  ## Parameters

  - `queue` - The event queue pid
  - `adapter_module` - The injector adapter module pushing the event
  - `event` - The event struct

  ## Example

      EventQueue.push(queue, MyApp.PaymentInjector, %PaymentConfirmed{order_id: "123"})
  """
  @spec push(pid(), module(), struct()) :: :ok
  def push(queue, adapter_module, event) do
    entry = %{
      event: event,
      adapter_module: adapter_module,
      timestamp: System.monotonic_time(:millisecond)
    }

    Agent.update(queue, fn events -> [entry | events] end)
  end

  @doc """
  Push an event from a resource poller.

  Events are timestamped automatically with monotonic time and tagged
  with their source as `:resource_poller`.

  ## Parameters

  - `queue` - The event queue pid
  - `poller_id` - Reference identifying the poller instance
  - `command_index` - Index of the command that started the poller
  - `event` - The event struct
  - `branch_id` - Optional branch identifier for parallel execution

  ## Example

      EventQueue.push_from_poller(queue, poller_ref, 5, %StatusChanged{id: "123"}, nil)
  """
  @spec push_from_poller(pid(), reference(), non_neg_integer(), struct(), non_neg_integer() | nil) ::
          :ok
  def push_from_poller(queue, poller_id, command_index, event, branch_id \\ nil) do
    entry = %{
      event: event,
      source: :resource_poller,
      poller_id: poller_id,
      command_index: command_index,
      branch_id: branch_id,
      timestamp: System.monotonic_time(:millisecond)
    }

    Agent.update(queue, fn events -> [entry | events] end)
  end

  @doc """
  Drain all pending events.

  Returns the list of events and clears the queue. Events are returned
  in the order they were pushed.

  ## Returns

  List of event entries. Every entry has `:event` and `:timestamp`. An entry
  from `push/3` also has `:adapter_module`; an entry from `push_from_poller/5`
  has `:source`, `:poller_id`, `:command_index` and `:branch_id` instead (see
  "Event Entries").

  ## Example

      entries = EventQueue.drain(queue)

      Enum.each(entries, fn
        %{adapter_module: adapter, event: event} ->
          IO.puts("Event from \#{adapter}: \#{inspect(event)}")

        %{source: :resource_poller, poller_id: poller, event: event} ->
          IO.puts("Event from poller \#{inspect(poller)}: \#{inspect(event)}")
      end)
  """
  @spec drain(pid()) :: [entry()]
  def drain(queue) do
    Agent.get_and_update(queue, fn events -> {Enum.reverse(events), []} end)
  end

  @doc """
  Peek at pending events without removing them.

  Useful for debugging or when you need to check without consuming.

  ## Example

      count = queue |> EventQueue.peek() |> length()
  """
  @spec peek(pid()) :: [entry()]
  def peek(queue) do
    Agent.get(queue, &Enum.reverse/1)
  end

  @doc """
  Check if the queue is empty.

  ## Example

      if EventQueue.empty?(queue) do
        IO.puts("No pending events")
      end
  """
  @spec empty?(pid()) :: boolean()
  def empty?(queue) do
    Agent.get(queue, &Enum.empty?/1)
  end

  @doc """
  Get the number of pending events.

  ## Example

      count = EventQueue.size(queue)
  """
  @spec size(pid()) :: non_neg_integer()
  def size(queue) do
    Agent.get(queue, &length/1)
  end
end
