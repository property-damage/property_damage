defmodule PropertyDamage.Forensics.EventMapping do
  @moduledoc false

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
