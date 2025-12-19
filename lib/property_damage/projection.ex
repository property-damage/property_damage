defmodule PropertyDamage.Projection do
  @moduledoc """
  Behaviour for projections in stateful property-based testing.

  Projections are pure reducers that interpret the execution stream (commands
  and events) into state. They are the ONLY place where commands and events
  are interpreted into state, providing a unified model for state management.

  ## Key Insight

  The "model state" used for command preconditions is itself a projection.
  This unifies the design - there's no special handling for events vs commands,
  just projections that interpret the execution stream however they need.

  ## Design Deviation: Commands in Projections

  Traditional event sourcing dictates that state should be derived only from
  events (immutable facts), not commands (requests). PropertyDamage intentionally
  deviates from this principle because:

  1. **Unified execution stream**: The test execution trace consists of commands
     and events interleaved. Projections see this same stream, enabling
     consistent reasoning about "what happened."

  2. **No artificial events**: Without this, tracking command-level information
     (e.g., "how many RefundOrder attempts?") would require creating synthetic
     events like `RefundAttempted`. This pollutes the event model.

  3. **Practical testing needs**: Test assertions often care about what was
     *attempted*, not just what *succeeded*. For example: "after 3 failed
     refund attempts, the account should be flagged."

  ## Execution Order

  For each command execution, `apply/2` is called with:
  1. The command first (if you need to track attempts)
  2. Then each resulting event (the facts of what happened)

  ```
  apply(state, %RefundOrder{...})      # command first
  apply(state, %RefundFailed{...})     # then event
  ```

  ## Example

      defmodule MyTest.Projections.ModelState do
        @behaviour PropertyDamage.Projection

        @impl true
        def init, do: %{orders: %{}, deleted_orders: MapSet.new()}

        @impl true
        def apply(state, %OrderCreated{order_ref: ref, amount: amt}) do
          put_in(state, [:orders, ref], %{amount: amt, status: :created})
        end

        def apply(state, %OrderDeleted{order_ref: ref}) do
          state
          |> update_in([:orders], &Map.delete(&1, ref))
          |> update_in([:deleted_orders], &MapSet.put(&1, ref))
        end

        # Catch-all: ignore unhandled commands/events
        def apply(state, _), do: state
      end

  ## Implementation Note

  Always include a catch-all clause `def apply(state, _), do: state` to
  handle commands/events that your projection doesn't care about.
  """

  @doc """
  Initialize the projection state.

  Called once at the start of each test run to create the initial state.
  """
  @callback init() :: any()

  @doc """
  Apply a command or event to the state.

  Called for each command and event in the execution stream.
  Should return the new state.

  The `command_or_event` parameter can be either:
  - A command struct (the attempted operation)
  - An event struct (the resulting fact)
  """
  @callback apply(state :: any(), command_or_event :: struct()) :: any()
end
