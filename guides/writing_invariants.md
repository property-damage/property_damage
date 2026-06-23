# Writing Effective Invariants

Invariants are the heart of property-based testing. They define what "correct"
means for your system. This guide covers how to write invariants that catch
real bugs.

## How an Invariant Signals Failure

A synchronous assertion (a `@trigger`-annotated function in an assertion
projection) **fails by raising**. The executor runs your assertion and treats a
raised exception as a violation; if the function returns without raising, the
assertion passed. The return value is ignored.

Use `PropertyDamage.fail!/2` to raise a structured failure:

```elixir
@trigger every: 1
def assert_balance_non_negative(state, _cmd_or_event) do
  if state.balance < 0 do
    PropertyDamage.fail!("balance is negative", balance: state.balance)
  end
end
```

> **Do not** return `{:error, "..."}` to signal a violation. A returned tuple is
> discarded, so the assertion silently passes and the bug is never caught. Raise
> (via `PropertyDamage.fail!/2` or any exception) instead.

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

  unless Enum.empty?(mismatches) do
    PropertyDamage.fail!("Balance mismatches", mismatches: mismatches)
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

  unless length(emails) == length(unique_emails) do
    duplicates = emails -- unique_emails
    PropertyDamage.fail!("Duplicate emails", duplicates: duplicates)
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

  unless Enum.empty?(invalid) do
    PropertyDamage.fail!("Invalid transitions", invalid: invalid)
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

  unless Enum.empty?(orphan_orders) do
    PropertyDamage.fail!("Orphan orders", ids: Enum.map(orphan_orders, &elem(&1, 0)))
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

  unless Enum.empty?(negative) do
    PropertyDamage.fail!("Negative balances", negative: negative)
  end
end

@trigger every: 1
def assert_inventory_non_negative(state, _cmd_or_event) do
  negative =
    state.inventory
    |> Enum.filter(fn {_sku, qty} -> qty < 0 end)

  unless Enum.empty?(negative) do
    PropertyDamage.fail!("Negative inventory", negative: negative)
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

  unless Enum.empty?(invalid) do
    PropertyDamage.fail!("Authorizations with invalid expiry", invalid: invalid)
  end
end
```

## Invariant Triggers

Control when invariants are checked using the `@trigger` attribute. The trigger
takes an `every:` key:

```elixir
# Check after every step (every: 1)
@trigger every: 1
def assert_balance_non_negative(state, _cmd_or_event) do
  # ...
end

# Sample expensive checks periodically (every Nth step)
@trigger every: 25
def assert_full_consistency_check(state, _cmd_or_event) do
  # ...
end

# Check after a specific command/event module
@trigger every: OrderCreated
def assert_order_valid(state, _cmd_or_event) do
  # ...
end
```

Supported `every:` forms: `1` (every step), `N` (every Nth step),
`:command`/`:event` (after any command/event), `Module`/`[Modules]` (after a
specific module), and `{N, target}` variants. Sample with `every: N` for
expensive checks.

### Lifecycle-boundary checks (`at:`)

`@trigger` has a second timing axis, `at:`, for a one-shot check at a lifecycle
boundary instead of during the command loop. An assertion uses `every:` or
`at:`, never both.

```elixir
# Once on the initial init/0 state, before the first command.
@trigger at: :startup
def assert_clean_start(state, _phase), do: # ...

# Once on the fully-settled final state, after all pollers finalize.
@trigger at: :teardown
def assert_no_overshoot(state, _phase), do: # ...
```

`at: :teardown` is the home for **safety** properties over async effects ("never
applied more than once"), the dual of `@poll_state`'s liveness. Because it runs
on the final folded state, the projection must **accumulate** evidence (a
maximum, a sticky flag) rather than snapshot, or a self-healed transient slips
past. See the [Async and Eventual Consistency](async_and_eventual_consistency.md)
guide for the safety/liveness pairing and the accumulator contract.

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

  @trigger every: 25
  def assert_no_suspicious_patterns(state, _cmd_or_event) do
    unless Enum.empty?(state.suspicious_patterns) do
      PropertyDamage.fail!("Suspicious patterns detected", patterns: state.suspicious_patterns)
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
  unless Map.get(state.active_faults, :network_partition) do
    if state.last_latency_ms >= 100 do
      PropertyDamage.fail!("SLA violated", latency_ms: state.last_latency_ms)
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
  if state.cache.hits / state.cache.total <= 0.8 do
    PropertyDamage.fail!("Low cache hits")
  end
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
  if DateTime.diff(DateTime.utc_now(), state.last_activity, :second) >= 60 do
    PropertyDamage.fail!("No recent activity")
  end
end
```

**Good**: Use logical time from events

```elixir
# Use event timestamps, not wall clock
@trigger every: 1
def assert_activity_ordering(state, _cmd_or_event) do
  sorted = Enum.sort_by(state.activities, & &1.timestamp)
  unless state.activities == sorted, do: PropertyDamage.fail!("Out of order")
end
```

### 3. Too Specific

**Bad**: Checks exact values

```elixir
# Too specific - will break with any change
@trigger every: 1
def assert_exact_balance(state, _cmd_or_event) do
  unless state.accounts["acc_1"].balance == 1000, do: PropertyDamage.fail!("Wrong")
end
```

**Good**: Check relationships

```elixir
# Check the relationship, not specific values
@trigger every: 1
def assert_credits_minus_debits(state, _cmd_or_event) do
  expected = state.total_credits - state.total_debits
  actual = Enum.reduce(state.accounts, 0, fn {_, acc}, sum -> sum + acc.balance end)
  unless expected == actual, do: PropertyDamage.fail!("Mismatch")
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
  IO.puts("Weak commands: #{inspect(analysis.weak_commands)}")
end
```

### Watching progress

A long mutation run can be slow, so pass an `on_progress` function to watch it.
It receives a `%PropertyDamage.Progress{}` projection (DR-022): a `MutationUpdate`
per mutation as it is killed, survived, or timed out, then a terminal
`MutationResult` carrying a copy of the final report. The same stream drives
`verbose:` and the `[:property_damage, :mutation, :progress | :result]` telemetry
events.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.{MutationResult, MutationUpdate}

PropertyDamage.Mutation.run(
  model: MyModel,
  adapter: MyAdapter,
  on_progress: fn
    %Progress{data: %MutationUpdate{result: outcome, command: command}} ->
      IO.puts("#{outcome}: #{inspect(command)}")

    %Progress{data: %MutationResult{report: report}} ->
      IO.puts("score: #{report.mutation_score}")
  end
)
```

The authoritative report is still the `{:ok, report}` return value;
`MutationResult` is a copy emitted for consumers.

## Next Steps

- [Debugging Failures](debugging_failures.md) - What to do when invariants catch bugs
- [Chaos Engineering](chaos_engineering.md) - Testing resilience with nemesis
- See `PropertyDamage.Suggestions` for invariant recommendations
