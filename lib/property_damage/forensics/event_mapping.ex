defmodule PropertyDamage.Forensics.EventMapping do
  @moduledoc """
  Behaviour for mapping production events to test event structs.

  Production events often have different field names, structures, or formats
  than the event structs used in your tests. Implement this behaviour to
  translate between them.

  ## Example

      defmodule MyEventMapping do
        @behaviour PropertyDamage.Forensics.EventMapping

        @impl true
        def map(%{"type" => "order.created", "payload" => p}) do
          {:ok, %OrderCreated{
            order_ref: p["order_id"],
            amount: p["total_cents"],
            currency: p["currency"]
          }}
        end

        def map(%{"type" => "payment.confirmed", "payload" => p}) do
          {:ok, %PaymentConfirmed{
            order_ref: p["order_id"],
            amount: p["amount"],
            provider_tx_id: p["stripe_charge_id"]
          }}
        end

        def map(%{"type" => type}) do
          {:skip, "Unknown event type: \#{type}"}
        end
      end

  ## Return Values

  - `{:ok, event}` - Successfully mapped to a test event struct
  - `:skip` - Skip this event (don't include in analysis)
  - `{:skip, reason}` - Skip with a reason (logged as warning)

  ## Tips

  1. **Handle unknown events gracefully** - Production logs may contain events
     your model doesn't care about. Return `:skip` for those.

  2. **Validate required fields** - If production data is missing fields your
     test events require, either provide defaults or return an error.

  3. **Handle format differences** - Production timestamps might be strings,
     amounts might be floats instead of integers, etc.
  """

  @doc """
  Map a production event to a test event struct.

  ## Parameters

  - `event` - The production event (typically a map with string keys)

  ## Returns

  - `{:ok, struct}` - Successfully mapped event
  - `:skip` - Event should be skipped
  - `{:skip, reason}` - Event skipped with reason
  """
  @callback map(event :: map() | struct()) ::
              {:ok, struct()} | :skip | {:skip, String.t()}
end
