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
@trigger every: 1
def assert_balance_matches_ledger(state, _cmd_or_event) do
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
@trigger every: 1
def assert_emails_unique(state, _cmd_or_event) do
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

@trigger every: 1
def assert_valid_status_transitions(state, _cmd_or_event) do
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
@trigger every: 1
def assert_orders_reference_valid_users(state, _cmd_or_event) do
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
@trigger every: 1
def assert_balances_non_negative(state, _cmd_or_event) do
  negative =
    state.accounts
    |> Enum.filter(fn {_id, account} -> account.balance < 0 end)

  if Enum.empty?(negative) do
    :ok
  else
    {:error, "Negative balances: #{inspect(negative)}"}
  end
end

@trigger every: 1
def assert_inventory_non_negative(state, _cmd_or_event) do
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
@trigger every: 1
def assert_expiry_after_creation(state, _cmd_or_event) do
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

Control when invariants are checked using the `@trigger` attribute:

```elixir
# Check after every event (every: 1)
@trigger every: 1
def assert_balance_non_negative(state, _cmd_or_event) do
  # ...
end

# Check only at end of sequence (expensive checks)
@trigger at: :end_of_sequence
def assert_full_consistency_check(state, _cmd_or_event) do
  # ...
end

# Check after specific event types
@trigger every: OrderCreated
def assert_order_valid(state, _cmd_or_event) do
  # ...
end
```

## Tracking State for Invariants

Assertion projections can track their own state:

```elixir
defmodule MyApp.Projections.AuditInvariants do
  use PropertyDamage.Model.Projection

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

  @trigger at: :end_of_sequence
  def assert_no_suspicious_patterns(state, _cmd_or_event) do
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
@trigger every: 1
def assert_latency_within_sla(state, _cmd_or_event) do
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
@trigger every: 1
def assert_cache_hit_ratio(state, _cmd_or_event) do
  if state.cache.hits / state.cache.total > 0.8, do: :ok, else: {:error, "Low cache hits"}
end
```

**Good**: Check observable behavior

```elixir
# Check what users can observe
@trigger every: 1
def assert_orders_match_line_items(state, _cmd_or_event) do
  # Sum of line items should equal order total
  ...
end
```

### 2. Non-Deterministic Checks

**Bad**: Time-dependent checks that can flake

```elixir
# Don't do this - can fail due to timing
@trigger every: 1
def assert_recent_activity(state, _cmd_or_event) do
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
@trigger every: 1
def assert_activity_ordering(state, _cmd_or_event) do
  sorted = Enum.sort_by(state.activities, & &1.timestamp)
  if state.activities == sorted, do: :ok, else: {:error, "Out of order"}
end
```

### 3. Too Specific

**Bad**: Checks exact values

```elixir
# Too specific - will break with any change
@trigger every: 1
def assert_exact_balance(state, _cmd_or_event) do
  if state.accounts["acc_1"].balance == 1000, do: :ok, else: {:error, "Wrong"}
end
```

**Good**: Check relationships

```elixir
# Check the relationship, not specific values
@trigger every: 1
def assert_credits_minus_debits(state, _cmd_or_event) do
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
