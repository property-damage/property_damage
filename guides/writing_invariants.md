# Writing Effective Invariants

Invariants are the heart of property-based testing. They define what "correct"
means for your system. This guide covers how to write invariants that catch
real bugs.

## How an Invariant Signals Failure

A synchronous check (a `@check`-annotated function in a check projection)
**passes by returning a truthy value** and fails on `nil` or `false`, like a
predicate given to `Enum.filter/2` (DR-052). A raise is a failure too. Write a
check in one of three forms:

```elixir
# A predicate: the shortest check.
@check every: 1
def balance_non_negative(state, _cmd_or_event), do: state.balance >= 0

# A predicate with a message: fail!/2 raises when the condition is false.
@check every: 1
def assert_balance_non_negative(state, _cmd_or_event) do
  state.balance >= 0 or PropertyDamage.fail!("balance is negative", balance: state.balance)
end

# A body that ends with a truthy value, such as the :ok of Enum.each/2.
@check every: 1
def assert_no_negative_accounts(state, _cmd_or_event) do
  Enum.each(state.accounts, fn {id, account} ->
    account.balance >= 0 or PropertyDamage.fail!("negative account", id: id)
  end)
end
```

A check that returns `nil` or `false` fails with a message that names it and
shows the value, for example: "check `balance_non_negative` returned `false`;
a check passes by returning a truthy value: a predicate,
`condition or fail!(...)`, or a body that ends with `:ok`".

`{:fail, reason}` is the returned form of `fail!/2`: it fails the check with
that reason without raising, so `condition || {:fail, "reason"}` is the
shortest reasoned check. The reason is a string, which becomes a
`PropertyDamage.CheckFailed` like the one `fail!/2` raises, or an exception,
which is kept as it is.

The `if condition, do: fail!(...)` idiom is retired: it returns `nil` when the
check passes. A `@check` whose last expression is an `if` or `unless` without
`else` does not compile. A bare exception struct or an `{:error, _}` tuple is
not a verdict either: the check fails with a message that says so, because
neither can have meant "pass".

### Composing sub-checks

A verdict is a final value, never a boolean. `&&`, `||`, `!` and
`Enum.all?/2` see a `{:fail, _}` as truthy, so `balance_ok(a) && limit_ok(a)`
passes when `balance_ok/1` returns `{:fail, "overdrawn"}`. Compose sub-checks
with `with`, which stops at the first value that is not `true`:

```elixir
@check every: 1
def account_valid(state, _cmd_or_event) do
  with true <- balance_ok(state.account),
       true <- limit_ok(state.account),
       do: true
end

defp balance_ok(account), do: account.balance >= 0 || {:fail, "overdrawn"}
defp limit_ok(account), do: account.spent <= account.limit || {:fail, "over limit"}
```

Or give each sub-check a raising helper and run them under `Enum.each/2`,
which returns `:ok` when none raised:

```elixir
@check every: 1
def accounts_valid(state, _cmd_or_event) do
  Enum.each(state.accounts, &balance_ok!/1)
end

defp balance_ok!({id, account}),
  do: account.balance >= 0 or PropertyDamage.fail!("overdrawn", id: id)
```

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
@check every: 1
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

  Enum.empty?(mismatches) or PropertyDamage.fail!("Balance mismatches", mismatches: mismatches)
end
```

### 2. Uniqueness Invariants

Verify uniqueness constraints:

```elixir
@check every: 1
def assert_emails_unique(state, _cmd_or_event) do
  emails = Enum.map(state.users, fn {_id, user} -> user.email end)
  unique_emails = Enum.uniq(emails)

  length(emails) == length(unique_emails) or
    PropertyDamage.fail!("Duplicate emails", duplicates: emails -- unique_emails)
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

@check every: 1
def assert_valid_status_transitions(state, _cmd_or_event) do
  invalid =
    state.transition_history
    |> Enum.filter(fn {from, to} ->
      valid_next = Map.get(@valid_transitions, from, [])
      to not in valid_next
    end)

  Enum.empty?(invalid) or PropertyDamage.fail!("Invalid transitions", invalid: invalid)
end
```

### 4. Referential Integrity Invariants

Verify foreign key relationships:

```elixir
@check every: 1
def assert_orders_reference_valid_users(state, _cmd_or_event) do
  user_ids = MapSet.new(Map.keys(state.users))

  orphan_orders =
    state.orders
    |> Enum.filter(fn {_id, order} ->
      order.user_id not in user_ids
    end)

  Enum.empty?(orphan_orders) or
    PropertyDamage.fail!("Orphan orders", ids: Enum.map(orphan_orders, &elem(&1, 0)))
end
```

### 5. Bounds Invariants

Verify values stay within acceptable ranges:

```elixir
@check every: 1
def assert_balances_non_negative(state, _cmd_or_event) do
  negative =
    state.accounts
    |> Enum.filter(fn {_id, account} -> account.balance < 0 end)

  Enum.empty?(negative) or PropertyDamage.fail!("Negative balances", negative: negative)
end

@check every: 1
def assert_inventory_non_negative(state, _cmd_or_event) do
  negative =
    state.inventory
    |> Enum.filter(fn {_sku, qty} -> qty < 0 end)

  Enum.empty?(negative) or PropertyDamage.fail!("Negative inventory", negative: negative)
end
```

### 6. Temporal Invariants

Verify time-based constraints:

```elixir
@check every: 1
def assert_expiry_after_creation(state, _cmd_or_event) do
  invalid =
    state.authorizations
    |> Enum.filter(fn {_id, auth} ->
      DateTime.compare(auth.expires_at, auth.created_at) != :gt
    end)

  Enum.empty?(invalid) or
    PropertyDamage.fail!("Authorizations with invalid expiry", invalid: invalid)
end
```

## The Three Kinds of Check

A projection can carry three kinds of check. Each is a function with a
decorating attribute, and each answers a different question.

| Kind | Question | Looks at | Schedule | Fails when |
|------|----------|----------|----------|------------|
| `@check` | Does this hold now? | One target's state | `every:` (`1`, `N`, `:command`, `:event`, `Module`, `[Modules]`, `{N, target}`) or `at:` (`:startup`, `:teardown`) | the function returns `nil`, `false` or `{:fail, reason}`, or raises |
| `@eventually` | Does this become true in time? | One target's state, polled | `after:` (event module or list), polled every `interval:` for up to `timeout:` | the predicate is still falsy at the `timeout:`, returns `{:fail, reason}`, or raises |
| `@compare` | Do the targets agree? | The same observation in two or more targets | `every:` (`1`, `N`, `{N, Module}`, `Module`, `[Modules]`, `:end`), agreement predicate `using:` | ready sides differ (`:diverged`) or a side is still `{:pending, reason}` at the bound (`:did_not_converge`) |

When to pick which:

- Use `@check` for a property that must hold right after a command or event: a
  balance never goes negative, ids are unique. Use `at: :teardown` for a safety
  property over asynchronous effects, checked once on the final state.
- Use `@eventually` for a property that holds only after the system catches up:
  a payment confirms, a webhook arrives. The poller starts when an `after:`
  event arrives and stops when the predicate first returns true.
- Use `@compare` when the question needs two or more targets. A `@check` in one
  target cannot see another target, so `@compare` is the whole cross-target
  oracle.

A function carries exactly one of the three. The three share one verdict
grammar (DR-052): a `@check` judges its return now, an `@eventually` judges its
predicate's return within the window, and a `@compare` judges its value against
the reference's through the `using:` relation, whose return is read the same
way. In all three a truthy return is good, a raise is a failure, and
`{:fail, reason}` is the reasoned failure.

The sections below teach `@check` first, then `@eventually`, then `@compare`.

## Check Triggers

Control when checks are run using the `@check` attribute. The trigger
takes an `every:` key:

```elixir
# Check after every step (every: 1)
@check every: 1
def assert_balance_non_negative(state, _cmd_or_event) do
  # ...
end

# Sample expensive checks periodically (every Nth step)
@check every: 25
def assert_full_consistency_check(state, _cmd_or_event) do
  # ...
end

# Check after a specific command/event module
@check every: OrderCreated
def assert_order_valid(state, _cmd_or_event) do
  # ...
end
```

Supported `every:` forms: `1` (every step), `N` (every Nth step),
`:command`/`:event` (after any command/event), `Module`/`[Modules]` (after a
specific module), and `{N, target}` variants. Sample with `every: N` for
expensive checks.

### Lifecycle-boundary checks (`at:`)

`@check` has a second timing axis, `at:`, for a one-shot check at a lifecycle
boundary instead of during the command loop. A check uses `every:` or
`at:`, never both.

```elixir
# Once on the initial init/0 state, before the first command.
@check at: :startup
def assert_clean_start(_state, _phase), do: :ok

# Once on the fully-settled final state, after all pollers finalize.
@check at: :teardown
def assert_no_overshoot(_state, _phase), do: :ok
```

`at: :teardown` is the home for **safety** properties over async effects ("never
applied more than once"), the dual of `@eventually`'s liveness. Because it runs
on the final folded state, the projection must **accumulate** evidence (a
maximum, a sticky flag) rather than snapshot, or a self-healed transient slips
past. See the [Async and Eventual Consistency](async_and_eventual_consistency.md)
guide for the safety/liveness pairing and the accumulator contract.

## Eventual Checks with `@eventually`

A `@eventually` function takes the projection state and the event that opened
the window, and returns a predicate over the projection state. The framework
polls the predicate until it returns a truthy value or the `timeout:` passes.
All three options are required, and a bare integer means seconds; use
`{n, unit}` with `:millisecond(s)`, `:second(s)` or `:minute(s)` for anything
else:

```elixir
@eventually after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
def payment_confirmed(_state, %PaymentInitiated{id: id}) do
  fn state ->
    case get_in(state, [:payments, id]) do
      :confirmed -> true
      :failed -> {:fail, "payment #{id} reached :failed"}
      _pending -> false
    end
  end
end
```

The predicate's return is a verdict: `nil` or `false` means "not yet", a
truthy value means satisfied, and `{:fail, reason}` means "never", which ends
the window at once as a check failure. Write the predicate as a total function
of the state: a raise inside it is a check failure at the first poll, not "not
yet". A predicate that has not become true by the `timeout:` fails the run with
a `:poll_timeout` failure. Such a failure can mean the system is slow, not wrong,
so raise the `timeout:` before you suspect a bug. A predicate cannot express
"never too many", because it stops at the first true value: pair it with a
`@check at: :teardown` for that. See
[Async and Eventual Consistency](async_and_eventual_consistency.md) for the
pairing and for the other two waits (`settle:` and `converge_within:`).

## Comparing Targets with `@compare`

A check looks at one run of one target. When a run has two or more `targets:`,
the question "do they agree?" needs a function that both targets answer, and
that function is a **boundary observation**: a public projection function
`def name(state, root)` marked `@compare`. Each target evaluates it on its own
projection state after a root, and every target's value is judged against the
first target's (the reference's):

```elixir
defmodule Bank.Projections.Ledger do
  use PropertyDamage.Model.Projection

  # init/0 and apply/2 fold the balance each target reports

  @compare every: 1
  def balance(state, _root), do: state.balance
end
```

`every:` takes the same schedule vocabulary as `@check` (`1`, `N`,
`{N, Module}`, `Module`, `[Modules]`) plus `:end` for the final boundary.
`using:` is a 2-arity predicate (default `&==/2`) whose return is a verdict:
truthy when the values agree, `false` or `{:fail, reason}` when they do not. A function may return
`{:pending, reason}` while its target is still catching up; the comparison
waits for it up to the run's `compare: [converge_within: ms]` (default 5000). A raise in a
`@compare` function or a `using:` predicate is a check failure naming the
observation. A `@compare` function cannot also carry `@check` or `@eventually`, and carries
one `@compare`, written above its first clause: a second one on another clause
is a compile error.

The [Differential Testing](differential_testing.md) guide covers the schedule,
the predicate helpers, `{:pending, reason}` and the convergence loop in full.

### What `==` does not do

`==` is what `assert a == b` uses, so authors are calibrated to it, and
`using: &===/2` is the strict form. Five traps each produce a false
"diverged":

1. **List order.** Lists are ordered, and `normalize/1` does not sort. An
   observation that returns a list whose order is not part of the contract
   diverges when injector-delivered events were folded in a different order per
   target. Return a map unless order is meant, or sort under
   `by_key(&Enum.sort/1)`. The framework never sorts silently, because order is
   sometimes the property under test.
2. **Keyword lists.** Keyword lists compare as lists, so `[a: 1, b: 2]` and
   `[b: 2, a: 1]` differ. Maps and `MapSet`s compare without regard to order.
3. **Number coercion.** `==` coerces numbers: `100 == 100.0`. That hides an
   integer-cents against float difference. Use `&===/2` when the
   representation matters.
4. **Value structs.** `Decimal`, `Money` and `DateTime` compare field by field:
   `Decimal.new("1.0") != Decimal.new("1.00")`, and two `DateTime` values that
   differ in microsecond precision or zone differ. Compare a key under
   `by_key/1` instead.
5. **Floats.** Floats differ in the last bit across implementations. Use a
   tolerance predicate such as `fn a, b -> abs(a - b) <= 0.01 end`.

Server-minted identifiers and timestamps break equality the same way: leave
them out of the observation, or strip them with
`PropertyDamage.Equivalence.normalize/1`.

## Tracking State for Checks

Check projections can track their own state:

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

  @check every: 25
  def assert_no_suspicious_patterns(state, _cmd_or_event) do
    Enum.empty?(state.suspicious_patterns) or
      PropertyDamage.fail!("Suspicious patterns detected", patterns: state.suspicious_patterns)
  end
end
```

## Relaxing Invariants During Faults

When using nemesis (chaos engineering), some invariants may not apply:

```elixir
@check every: 1
def assert_latency_within_sla(state, _cmd_or_event) do
  # Skip SLA check during active network partition
  partitioned? = Map.get(state.active_faults, :network_partition, false)

  partitioned? or state.last_latency_ms < 100 or
    PropertyDamage.fail!("SLA violated", latency_ms: state.last_latency_ms)
end
```

## Common Mistakes

### 1. Checking Implementation Details

**Bad**: Checking internal counters or cache state

```elixir
# Don't do this - relies on implementation details
@check every: 1
def assert_cache_hit_ratio(state, _cmd_or_event) do
  state.cache.hits / state.cache.total > 0.8 or PropertyDamage.fail!("Low cache hits")
end
```

**Good**: Check observable behavior

```elixir
# Check what users can observe
@check every: 1
def assert_orders_match_line_items(state, _cmd_or_event) do
  # Sum of line items should equal order total
  ...
end
```

### 2. Non-Deterministic Checks

**Bad**: Time-dependent checks that can flake

```elixir
# Don't do this - can fail due to timing
@check every: 1
def assert_recent_activity(state, _cmd_or_event) do
  DateTime.diff(DateTime.utc_now(), state.last_activity, :second) < 60 or
    PropertyDamage.fail!("No recent activity")
end
```

**Good**: Use logical time from events

```elixir
# Use event timestamps, not wall clock
@check every: 1
def assert_activity_ordering(state, _cmd_or_event) do
  sorted = Enum.sort_by(state.activities, & &1.timestamp)
  state.activities == sorted or PropertyDamage.fail!("Out of order")
end
```

### 3. Too Specific

**Bad**: Checks exact values

```elixir
# Too specific - will break with any change
@check every: 1
def assert_exact_balance(state, _cmd_or_event) do
  state.accounts["acc_1"].balance == 1000 or PropertyDamage.fail!("Wrong")
end
```

**Good**: Check relationships

```elixir
# Check the relationship, not specific values
@check every: 1
def assert_credits_minus_debits(state, _cmd_or_event) do
  expected = state.total_credits - state.total_debits
  actual = Enum.reduce(state.accounts, 0, fn {_, acc}, sum -> sum + acc.balance end)
  expected == actual or PropertyDamage.fail!("Mismatch")
end
```

## Using Mutation Testing to Validate Invariants

Use mutation testing to verify your invariants catch bugs:

```elixir
{:ok, report} = PropertyDamage.Mutation.run(
  model: MyModel,
  targets: [MyAdapter],
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
  targets: [MyAdapter],
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
- [Differential Testing](differential_testing.md) - Comparing targets through `@compare`
- [Path Equivalence Testing](path_equivalence_testing.md) - The same `@compare` observations across equivalent command sequences
- [Chaos Engineering](chaos_engineering.md) - Testing resilience with nemesis
- See `PropertyDamage.Suggestions` for invariant recommendations
