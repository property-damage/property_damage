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

  Each entry in the queue contains:

  - `event` - The event struct
  - `adapter_module` - The injector adapter that received it
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
  """
  @type entry :: %{
          event: struct(),
          adapter_module: module(),
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

      EventQueue.push(queue, MyInjectorAdapter, %PaymentConfirmed{order_id: "123"})
  """
  @spec push(pid(), module(), struct()) :: :ok
  def push(queue, adapter_module, event) do
    entry = %{
      event: event,
      adapter_module: adapter_module,
      timestamp: System.monotonic_time(:millisecond)
    }

    Agent.update(queue, fn events -> events ++ [entry] end)
  end

  @doc """
  Drain all pending events.

  Returns the list of events and clears the queue. Events are returned
  in the order they were pushed.

  ## Returns

  List of event entries, each containing `:event`, `:adapter_module`,
  and `:timestamp`.

  ## Example

      entries = EventQueue.drain(queue)
      Enum.each(entries, fn %{event: event, adapter_module: adapter} ->
        IO.puts("Event from \#{adapter}: \#{inspect(event)}")
      end)
  """
  @spec drain(pid()) :: [entry()]
  def drain(queue) do
    Agent.get_and_update(queue, fn events -> {events, []} end)
  end

  @doc """
  Peek at pending events without removing them.

  Useful for debugging or when you need to check without consuming.

  ## Example

      count = queue |> EventQueue.peek() |> length()
  """
  @spec peek(pid()) :: [entry()]
  def peek(queue) do
    Agent.get(queue, & &1)
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
