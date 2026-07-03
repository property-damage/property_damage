defmodule PropertyDamage.SuggestionsFixtures do
  @moduledoc """
  Realistic fixtures for exercising the `PropertyDamage.Suggestions` analyze
  pipeline end to end.

  Unlike the vacuous `commands, do: []` models used elsewhere, these models
  declare commands that actually resolve to event structs, so
  `Analyzer.get_emitted_events/1` yields non-empty event lists and the
  suggestion generators produce concrete output.

  Both event-resolution paths in the analyzer are covered:

    * **Name inference** (`Commands.CreateAccount` -> `Events.AccountCreated`):
      the `Create`/`Credit`/`Debit`/`Update` commands carry no `@emits`, so the
      analyzer infers their events from the sibling `Events` namespace.

    * **`@emits` attribute** (`Commands.PlaceOrder` -> `Events.OrderCreated`):
      `PlaceOrder` has no verb the inference recognises, so `OrderCreated` can
      only be resolved through the persisted `@emits` attribute.
  """

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Events.AccountCreated do
    @moduledoc false
    defstruct [:account_ref, :balance, :currency, :opened_at]
  end

  defmodule Events.AccountCredited do
    @moduledoc false
    defstruct [:account_ref, :amount, :currency, :new_balance]
  end

  defmodule Events.AccountDebited do
    @moduledoc false
    defstruct [:account_ref, :amount, :currency, :new_balance]
  end

  defmodule Events.OrderUpdated do
    @moduledoc false
    defstruct [:order_ref, :status, :updated_at]
  end

  defmodule Events.OrderCreated do
    @moduledoc false
    defstruct [:order_ref, :total_amount, :status, :placed_at]
  end

  # ==========================================================================
  # Commands (name-inference path)
  # ==========================================================================

  defmodule Commands.CreateAccount do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:balance, :currency]

    @impl true
    def generator(overrides \\ %{}) do
      %{balance: StreamData.integer(), currency: StreamData.constant("USD")}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Commands.CreditAccount do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account_ref, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Commands.DebitAccount do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account_ref, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Commands.UpdateOrder do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:order_ref, :status]

    @impl true
    def generator(overrides \\ %{}) do
      %{status: StreamData.member_of([:open, :closed])}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Command (@emits path)
  # ==========================================================================

  defmodule Commands.PlaceOrder do
    @moduledoc false
    use PropertyDamage.Command

    # "PlaceOrder" matches none of the analyzer's verb transforms, so the only
    # way OrderCreated can surface is via this persisted @emits attribute.
    Module.register_attribute(__MODULE__, :emits, persist: true, accumulate: false)
    @emits [PropertyDamage.SuggestionsFixtures.Events.OrderCreated]

    defstruct [:total_amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{total_amount: StreamData.positive_integer()}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Command that resolves to no events (empty-degradation path)
  # ==========================================================================

  defmodule Commands.Frobnicate do
    @moduledoc false
    use PropertyDamage.Command

    # No @emits, and "Frobnicate" matches no verb transform, so this command
    # resolves to zero events.
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> PropertyDamage.Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule Projections.Empty do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state
  end

  defmodule Projections.BalanceChecked do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @trigger every: 1
    def assert_balance_non_negative(_state, _cmd_or_event), do: :ok
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  defmodule FullModel do
    @moduledoc "Commands resolve to events; no existing assertion projections."
    @behaviour PropertyDamage.Model

    alias PropertyDamage.SuggestionsFixtures.{Commands, Projections}

    @impl true
    def commands,
      do: [
        Commands.CreateAccount,
        Commands.CreditAccount,
        Commands.DebitAccount,
        Commands.UpdateOrder,
        Commands.PlaceOrder
      ]

    @impl true
    def command_sequence_projection, do: Projections.Empty

    @impl true
    def assertion_projections, do: []
  end

  defmodule CheckedModel do
    @moduledoc "Same commands as FullModel, but with an existing balance check."
    @behaviour PropertyDamage.Model

    alias PropertyDamage.SuggestionsFixtures.{Commands, Projections}

    @impl true
    def commands,
      do: [
        Commands.CreateAccount,
        Commands.CreditAccount,
        Commands.DebitAccount,
        Commands.UpdateOrder,
        Commands.PlaceOrder
      ]

    @impl true
    def command_sequence_projection, do: Projections.Empty

    @impl true
    def assertion_projections, do: [Projections.BalanceChecked]
  end

  defmodule NoEventsModel do
    @moduledoc "A command that resolves to no events at all."
    @behaviour PropertyDamage.Model

    alias PropertyDamage.SuggestionsFixtures.{Commands, Projections}

    @impl true
    def commands, do: [Commands.Frobnicate]

    @impl true
    def command_sequence_projection, do: Projections.Empty

    @impl true
    def assertion_projections, do: []
  end
end
