defmodule PropertyDamage.Adapter.Injector do
  @moduledoc """
  Behaviour for adapters that receive and inject external events.

  InjectorAdapters handle asynchronous event sources like webhooks, callbacks,
  message queues, or any external system that pushes events into the test.
  They transform incoming payloads into domain events and push them to the
  shared EventQueue for processing.

  ## Direction of Event Flow

  Unlike Adapter (which executes commands → produces events), InjectorAdapter
  receives external events → transforms → pushes to EventQueue:

  ```
  External System → InjectorAdapter.to_event/1 → EventQueue → Executor
  ```

  ## Lifecycle

  InjectorAdapters follow a similar lifecycle to Adapters:

  1. `setup/1` - Start listening (webhooks, subscriptions, etc.)
  2. External events arrive → `to_event/1` → `EventQueue.push/3`
  3. `teardown/1` - Stop listening, cleanup

  ## The @emits Attribute

  Declare which events this adapter can emit for validation:

  ```elixir
  @emits [PaymentConfirmed, PaymentDeclined]
  ```

  The framework uses this for:
  - Validating that Model.injectable_events/0 covers all possible injected events
  - Detecting orphan events that no assertion projection handles

  ## Example

      defmodule MyTest.PaymentWebhookAdapter do
        use PropertyDamage.Adapter.Injector

        @emits [PaymentConfirmed, PaymentDeclined]

        @impl true
        def setup(config) do
          {:ok, server} = MockWebhookServer.start_link(
            port: config[:port],
            handler: &handle_webhook(&1, config.event_queue)
          )
          {:ok, %{server: server}}
        end

        @impl true
        def teardown(%{server: server}) do
          MockWebhookServer.stop(server)
          :ok
        end

        @impl true
        def to_event(%{"type" => "payment.success", "order_id" => id}) do
          {:ok, %PaymentConfirmed{order_id: id}}
        end

        def to_event(%{"type" => "payment.failed", "order_id" => id, "reason" => r}) do
          {:ok, %PaymentDeclined{order_id: id, reason: r}}
        end

        def to_event(_unknown), do: :skip

        defp handle_webhook(payload, queue) do
          case to_event(payload) do
            {:ok, event} -> EventQueue.push(queue, __MODULE__, event)
            :skip -> :ok
          end
        end
      end

  ## Optional Responses

  Some systems expect responses to webhooks. Implement `respond/2` to generate:

      @impl true
      def respond(%PaymentConfirmed{}, _context) do
        {:ok, %{status: 200, body: ~s({"ack": true})}}
      end
  """

  @doc """
  Called once per run to start listening for external events.

  The config will include:
  - `:event_queue` - PID of the EventQueue for pushing events
  - Any adapter-specific config from the test setup

  ## Returns

  - `{:ok, context}` - Setup succeeded
  - `{:error, reason}` - Setup failed
  """
  @callback setup(config :: map()) :: {:ok, context :: map()} | {:error, term()}

  @doc """
  Called once per run to stop listening and cleanup.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown(context :: map()) :: :ok

  @doc """
  Transform an external payload into a domain event.

  Called when the adapter receives data from the external source.
  The payload format depends on the source (JSON, protobuf, raw data, etc.).

  ## Returns

  - `{:ok, event}` - Successfully transformed to domain event
  - `:skip` - Ignore this payload (not relevant to test)
  - `{:error, reason}` - Transformation failed
  """
  @callback to_event(payload :: term()) :: {:ok, struct()} | :skip | {:error, term()}

  @doc """
  Optional: Generate a response for the external system.

  Some webhook systems expect acknowledgment responses. Implement this
  callback to generate appropriate responses based on the event.

  ## Returns

  - `{:ok, response}` - Response to send back
  - `:none` - No response needed
  """
  @callback respond(event :: struct(), context :: map()) :: {:ok, term()} | :none

  @optional_callbacks [respond: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Adapter.Injector
      Module.register_attribute(__MODULE__, :emits, accumulate: false)
      @before_compile PropertyDamage.Adapter.Injector
    end
  end

  defmacro __before_compile__(env) do
    emits = Module.get_attribute(env.module, :emits) || []

    quote do
      @doc """
      Returns the list of event types this adapter can emit.

      Used by the framework for validation and coverage checking.
      """
      @spec __emits__() :: [module()]
      def __emits__, do: unquote(emits)
    end
  end
end
