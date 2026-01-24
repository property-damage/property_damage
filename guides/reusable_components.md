# Building Reusable Components

This guide explains how to build reusable command configurations, projections,
and simulators that work across different models with different state structures.

## The Problem

When building reusable command configurations, preconditions (`when:`) and
generators (`with:`) need to access state. But different models may structure
their state differently:

```elixir
# Model A: flat structure
%{authorizations: %{...}, captures: %{...}}

# Model B: nested structure
%{payment: %{auth: %{...}, capture: %{...}}, audit: %{...}}
```

A reusable `CapturePayment` command configuration needs to:
- Check if there are capturable authorizations (precondition)
- Select an authorization to capture (generator)

How can this work across both state structures?

## Solution: Protocols for State Access

Define protocols that abstract over state structure. Each model implements
the protocol for its specific state shape.

### Step 1: Define the Protocol

```elixir
defprotocol MyDomain.PaymentAccess do
  @doc "Get map of pending authorizations from state"
  def pending_authorizations(state)

  @doc "Get authorization by ID, or nil if not found"
  def get_authorization(state, id)

  @doc "Get list of approved authorization IDs"
  def approved_auth_ids(state)
end
```

### Step 2: Implement for Each State Structure

```elixir
# For Model A's flat structure
defimpl MyDomain.PaymentAccess, for: Map do
  def pending_authorizations(%{authorizations: auths}) do
    auths
    |> Enum.filter(fn {_id, auth} -> auth.status == :pending end)
    |> Map.new()
  end

  def get_authorization(%{authorizations: auths}, id) do
    Map.get(auths, id)
  end

  def approved_auth_ids(%{authorizations: auths}) do
    auths
    |> Enum.filter(fn {_id, auth} -> auth.status == :approved end)
    |> Enum.map(fn {id, _} -> id end)
  end
end
```

For Model B's nested structure, you might use a custom struct:

```elixir
defmodule MyDomain.FullPaymentState do
  defstruct [:payment, :audit]
end

defimpl MyDomain.PaymentAccess, for: MyDomain.FullPaymentState do
  def pending_authorizations(%{payment: %{auth: auths}}) do
    auths
    |> Enum.filter(fn {_id, auth} -> auth.status == :pending end)
    |> Map.new()
  end

  def get_authorization(%{payment: %{auth: auths}}, id) do
    Map.get(auths, id)
  end

  def approved_auth_ids(%{payment: %{auth: auths}}) do
    auths
    |> Enum.filter(fn {_id, auth} -> auth.status == :approved end)
    |> Enum.map(fn {id, _} -> id end)
  end
end
```

### Step 3: Write Reusable Command Configuration

```elixir
defmodule MyDomain.CommandConfigs do
  alias MyDomain.PaymentAccess

  @doc """
  Returns command spec for CapturePayment that works with any state
  implementing PaymentAccess protocol.
  """
  def capture_payment_spec do
    {CapturePayment,
      weight: 2,
      when: fn state ->
        PaymentAccess.approved_auth_ids(state) != []
      end,
      with: fn state ->
        auth_id = Enum.random(PaymentAccess.approved_auth_ids(state))
        auth = PaymentAccess.get_authorization(state, auth_id)
        %{
          auth_id: StreamData.constant(auth_id),
          amount: StreamData.integer(1..auth.amount)
        }
      end}
  end
end
```

### Step 4: Use in Models

```elixir
defmodule AuthOnlyModel do
  @behaviour PropertyDamage.Model

  import MyDomain.CommandConfigs

  def commands do
    [
      CreateAuth,
      ApproveAuth,
      capture_payment_spec()  # Reusable!
    ]
  end

  def command_sequence_state, do: FlatStateProjection
end

defmodule FullPaymentModel do
  @behaviour PropertyDamage.Model

  import MyDomain.CommandConfigs

  def commands do
    [
      CreateAuth,
      ApproveAuth,
      capture_payment_spec(),  # Same reusable spec!
      RefundPayment
    ]
  end

  def command_sequence_state, do: NestedStateProjection
end
```

## Reusable Assertion Projections

The same pattern works for assertion projections that need to access state
from different structures:

```elixir
defmodule BalanceInvariant do
  use PropertyDamage.Model.Projection

  alias MyDomain.PaymentAccess

  def init, do: %{total_authorized: 0, total_captured: 0}

  def apply(state, %AuthApproved{amount: amt}) do
    update_in(state.total_authorized, &(&1 + amt))
  end

  def apply(state, %CaptureCreated{amount: amt}) do
    update_in(state.total_captured, &(&1 + amt))
  end

  def apply(state, _), do: state

  @trigger every: 1
  def assert_captured_within_authorized(state, _context) do
    if state.total_captured > state.total_authorized do
      PropertyDamage.fail!("captured exceeds authorized",
        captured: state.total_captured,
        authorized: state.total_authorized)
    end
  end
end
```

This assertion projection tracks its own state and works regardless of
the main state projection's structure.

## When to Use Protocols

Protocols add complexity. Use them when:

- You have multiple models with genuinely different state structures
- The same command/assertion logic needs to work across them
- The benefit of reuse outweighs the protocol overhead

For simpler cases, direct state access is fine:

```elixir
# Simple: just access state directly
{CancelOrder,
  when: fn state -> map_size(state.orders) > 0 end,
  with: fn state -> %{order_id: Enum.random(Map.keys(state.orders))} end}
```

## Alternative: Helper Modules

For less formal reuse, extract helper functions:

```elixir
defmodule PaymentHelpers do
  def has_approved_auths?(%{authorizations: auths}) do
    Enum.any?(auths, fn {_, auth} -> auth.status == :approved end)
  end

  def random_approved_auth(%{authorizations: auths}) do
    auths
    |> Enum.filter(fn {_, auth} -> auth.status == :approved end)
    |> Enum.random()
    |> elem(0)
  end
end
```

Then use in command specs:

```elixir
{CapturePayment,
  when: &PaymentHelpers.has_approved_auths?/1,
  with: fn state ->
    %{auth_id: PaymentHelpers.random_approved_auth(state)}
  end}
```

This is simpler than protocols but assumes a consistent state structure.

## Summary

| Approach | When to Use |
|----------|-------------|
| Direct access | Single model or consistent state structure |
| Helper modules | Consistent structure, want to share logic |
| Protocols | Different state structures, maximum reuse |

The framework doesn't mandate any particular approach. Choose based on your
actual reuse requirements.
