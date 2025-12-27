# Writing Effective Invariants

Invariants are the heart of property-based testing. They define what "correct"
means for your system. This guide covers how to write invariants that catch
real bugs.

## What Makes a Good Invariant?

Good invariants are:

1. **Always true** - If it can be violated, the system has a bug
2. **Independently verifiable** - Can be checked without knowing how the system works internally
3. **Specific enough** - Catches bugs when violated
4. **General enough** - Doesn't fail due to timing or edge cases

## Types of Invariants

### 1. Balance Invariants

Track that quantities add up correctly:

```elixir
def check(:balance_matches_ledger, state, _ctx) do
  # Account balance should equal sum of all transactions
  expected_balances =
    state.transactions
    |> Enum.group_by(& &1.account_id)
    |> Enum.map(fn {account_id, txns} ->
      balance = Enum.reduce(txns, 0, fn
        %{type: :credit, amount: amt}, acc -> acc + amt
        %{type: :debit, amount: amt}, acc -> acc - amt
      end)
      {account_id, balance}
    end)
    |> Map.new()

  mismatches =
    state.accounts
    |> Enum.filter(fn {id, account} ->
      expected = Map.get(expected_balances, id, 0)
      account.balance != expected
    end)

  if Enum.empty?(mismatches) do
    :ok
  else
    {:error, "Balance mismatches: #{inspect(mismatches)}"}
  end
end
```

### 2. Uniqueness Invariants

Verify uniqueness constraints:

```elixir
def check(:emails_unique, state, _ctx) do
  emails = Enum.map(state.users, fn {_id, user} -> user.email end)
  unique_emails = Enum.uniq(emails)

  if length(emails) == length(unique_emails) do
    :ok
  else
    duplicates = emails -- unique_emails
    {:error, "Duplicate emails: #{inspect(duplicates)}"}
  end
end
```

### 3. State Machine Invariants

Verify valid state transitions:

```elixir
@valid_transitions %{
  :draft => [:pending, :cancelled],
  :pending => [:approved, :rejected, :cancelled],
  :approved => [:completed, :cancelled],
  :rejected => [],
  :cancelled => [],
  :completed => []
}

def check(:valid_status_transitions, state, _ctx) do
  invalid =
    state.transition_history
    |> Enum.filter(fn {from, to} ->
      valid_next = Map.get(@valid_transitions, from, [])
      to not in valid_next
    end)

  if Enum.empty?(invalid) do
    :ok
  else
    {:error, "Invalid transitions: #{inspect(invalid)}"}
  end
end
```

### 4. Referential Integrity Invariants

Verify foreign key relationships:

```elixir
def check(:orders_reference_valid_users, state, _ctx) do
  user_ids = MapSet.new(Map.keys(state.users))

  orphan_orders =
    state.orders
    |> Enum.filter(fn {_id, order} ->
      order.user_id not in user_ids
    end)

  if Enum.empty?(orphan_orders) do
    :ok
  else
    {:error, "Orphan orders: #{inspect(Enum.map(orphan_orders, &elem(&1, 0)))}"}
  end
end
```

### 5. Bounds Invariants

Verify values stay within acceptable ranges:

```elixir
def check(:balances_non_negative, state, _ctx) do
  negative =
    state.accounts
    |> Enum.filter(fn {_id, account} -> account.balance < 0 end)

  if Enum.empty?(negative) do
    :ok
  else
    {:error, "Negative balances: #{inspect(negative)}"}
  end
end

def check(:inventory_non_negative, state, _ctx) do
  negative =
    state.inventory
    |> Enum.filter(fn {_sku, qty} -> qty < 0 end)

  if Enum.empty?(negative) do
    :ok
  else
    {:error, "Negative inventory: #{inspect(negative)}"}
  end
end
```

### 6. Temporal Invariants

Verify time-based constraints:

```elixir
def check(:expiry_after_creation, state, _ctx) do
  invalid =
    state.authorizations
    |> Enum.filter(fn {_id, auth} ->
      DateTime.compare(auth.expires_at, auth.created_at) != :gt
    end)

  if Enum.empty?(invalid) do
    :ok
  else
    {:error, "Authorizations with invalid expiry: #{inspect(invalid)}"}
  end
end
```

## Invariant Triggers

Control when invariants are checked:

```elixir
def __checks__ do
  [
    # Check after every event
    %{name: :balance_non_negative, trigger: :always, sample: 1},

    # Check only at end of sequence (expensive checks)
    %{name: :full_consistency_check, trigger: :end_of_sequence, sample: 1},

    # Sample: check 10% of the time (for very expensive checks)
    %{name: :deep_validation, trigger: :always, sample: 0.1}
  ]
end
```

## Tracking State for Invariants

Assertion projections can track their own state:

```elixir
defmodule MyApp.Projections.AuditInvariants do
  @behaviour PropertyDamage.Projection

  @impl true
  def init do
    %{
      # Track what we need for invariant checks
      operation_counts: %{},
      last_operation_per_user: %{},
      suspicious_patterns: []
    }
  end

  @impl true
  def apply(state, %OperationCompleted{user_id: uid, op_type: type}) do
    state
    |> update_in([:operation_counts, type], &((&1 || 0) + 1))
    |> put_in([:last_operation_per_user, uid], type)
  end

  def apply(state, _), do: state

  def __checks__ do
    [%{name: :no_suspicious_patterns, trigger: :end_of_sequence, sample: 1}]
  end

  def check(:no_suspicious_patterns, state, _ctx) do
    if Enum.empty?(state.suspicious_patterns) do
      :ok
    else
      {:error, "Suspicious patterns detected: #{inspect(state.suspicious_patterns)}"}
    end
  end
end
```

## Relaxing Invariants During Faults

When using nemesis (chaos engineering), some invariants may not apply:

```elixir
def check(:latency_within_sla, state, _ctx) do
  # Skip SLA check during active network partition
  if Map.get(state.active_faults, :network_partition) do
    :ok
  else
    if state.last_latency_ms < 100 do
      :ok
    else
      {:error, "SLA violated: #{state.last_latency_ms}ms"}
    end
  end
end
```

## Common Mistakes

### 1. Checking Implementation Details

**Bad**: Checking internal counters or cache state

```elixir
# Don't do this - relies on implementation details
def check(:cache_hit_ratio, state, _ctx) do
  if state.cache.hits / state.cache.total > 0.8, do: :ok, else: {:error, "Low cache hits"}
end
```

**Good**: Check observable behavior

```elixir
# Check what users can observe
def check(:orders_match_line_items, state, _ctx) do
  # Sum of line items should equal order total
  ...
end
```

### 2. Non-Deterministic Checks

**Bad**: Time-dependent checks that can flake

```elixir
# Don't do this - can fail due to timing
def check(:recent_activity, state, _ctx) do
  if DateTime.diff(DateTime.utc_now(), state.last_activity, :second) < 60 do
    :ok
  else
    {:error, "No recent activity"}
  end
end
```

**Good**: Use logical time from events

```elixir
# Use event timestamps, not wall clock
def check(:activity_ordering, state, _ctx) do
  sorted = Enum.sort_by(state.activities, & &1.timestamp)
  if state.activities == sorted, do: :ok, else: {:error, "Out of order"}
end
```

### 3. Too Specific

**Bad**: Checks exact values

```elixir
# Too specific - will break with any change
def check(:exact_balance, state, _ctx) do
  if state.accounts["acc_1"].balance == 1000, do: :ok, else: {:error, "Wrong"}
end
```

**Good**: Check relationships

```elixir
# Check the relationship, not specific values
def check(:credits_minus_debits, state, _ctx) do
  expected = state.total_credits - state.total_debits
  actual = Enum.reduce(state.accounts, 0, fn {_, acc}, sum -> sum + acc.balance end)
  if expected == actual, do: :ok, else: {:error, "Mismatch"}
end
```

## Using Mutation Testing to Validate Invariants

Use mutation testing to verify your invariants catch bugs:

```elixir
{:ok, report} = PropertyDamage.Mutation.run(
  model: MyModel,
  adapter: MyAdapter,
  target_score: 0.80
)

# If mutation score is low, invariants need improvement
if report.mutation_score < 0.80 do
  analysis = PropertyDamage.Mutation.analyze(report)
  IO.puts("Weak invariants: #{inspect(analysis.weak_checks)}")
end
```

## Next Steps

- [Debugging Failures](debugging_failures.md) - What to do when invariants catch bugs
- [Chaos Engineering](chaos_engineering.md) - Testing resilience with nemesis
- See `PropertyDamage.Suggestions` for AI-powered invariant recommendations
