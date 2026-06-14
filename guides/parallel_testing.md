# Parallel Testing and Linearization

PropertyDamage can run commands concurrently across parallel branches to expose
race conditions. After execution, the framework checks whether the observed
results are linearizable -- explainable by some valid sequential ordering.

## Why Parallel Testing

Sequential tests miss timing-dependent bugs. A `Transfer` command that reads a
balance, computes the new value, and writes it back may work perfectly in
isolation but lose updates under concurrency. Parallel testing runs commands
simultaneously to surface these defects.

## Branching Sequences

A parallel test sequence has three parts:

```
Prefix (sequential setup):
  CreateAccount{id: "a"} -> CreateAccount{id: "b"}

Branches (parallel execution):
  Branch 1: Deposit{acc: ref0, amount: 100} -> Withdraw{acc: ref0, amount: 30}
  Branch 2: Deposit{acc: ref1, amount: 200} -> Transfer{from: ref0, to: ref1, amount: 50}

Suffix (optional sequential cleanup):
  CloseAccount{id: ref0} -> CloseAccount{id: ref1}
```

The **prefix** runs first to establish state. **Branches** run concurrently.
The **suffix** runs after all branches complete.

This maps directly to the `PropertyDamage.Sequence` struct:

```elixir
%PropertyDamage.Sequence{
  prefix: [%CreateAccount{}, %CreateAccount{}],
  branches: [
    [%Deposit{}, %Withdraw{}],
    [%Deposit{}, %Transfer{}]
  ],
  suffix: [%CloseAccount{}, %CloseAccount{}]
}
```

### Ref Constraints

- Refs created in the prefix can be used in any branch.
- Refs created in one branch CANNOT be used in another branch.
- Refs created in branches CAN be used in the suffix (after merge).

## Enabling Parallel Execution

Pass a `:branching` keyword list to `PropertyDamage.run/1`:

```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  branching: [
    max_branches: 3,
    max_branch_length: 5,
    min_prefix_length: 3,
    branch_probability: 0.2
  ]
)
```

### Branching Options

| Option | Type | Default | Description |
|---|---|---|---|
| `branch_probability` | `float` | `0.2` | Probability of creating a branch point (0.0--1.0) |
| `max_branches` | `pos_integer` | `3` | Maximum number of parallel branches |
| `max_branch_length` | `pos_integer` | `5` | Maximum commands per branch |
| `min_prefix_length` | `pos_integer` | `3` | Minimum commands before branching |

## Linearization Checking

After parallel branches execute, the framework asks: "Is there ANY sequential
ordering of these parallel commands that produces the observed results?"

The algorithm:

1. Generate all valid interleavings of the branch commands (preserving
   within-branch order).
2. For each interleaving, simulate execution through the model's projections.
3. Compare the simulated final state with the actual observed state.
4. If any interleaving matches, the execution is linearizable.

```elixir
case PropertyDamage.Linearization.check(branches, branch_events, projections, model) do
  {:ok, linearization} ->
    # A valid sequential ordering exists -- consistent behavior
    :ok

  {:no_linearization, _refutation} ->
    # No valid ordering explains the results -- race condition detected
    raise "Non-linearizable execution!"

  {:indeterminate, _checked} ->
    # Could not verify (no simulator, or the interleaving cap was reached)
    :ok
end
```

### Complexity

The number of possible interleavings grows as a multinomial coefficient. For
branches of lengths n1, n2, ..., nk:

```
count = (n1 + n2 + ... + nk)! / (n1! * n2! * ... * nk!)
```

Two branches of 5 commands each produce 252 interleavings. Three branches of 5
produce 756,756. The framework includes early termination (stop as soon as a
valid linearization is found) and feasibility checking:

```elixir
PropertyDamage.Linearization.feasibility(branches)
# => :ok                     (under 1000 interleavings)
# => {:warning, 756_756}     (may be slow)
```

Keep branch counts and lengths moderate to avoid combinatorial explosion.

## What It Detects

Parallel testing with linearization checking catches:

- **Lost updates** -- Two concurrent writes, one overwrites the other.
- **Dirty reads** -- Reading uncommitted data from a concurrent transaction.
- **Write-write conflicts** -- Two branches modify the same record, final state
  matches neither.
- **Phantom reads** -- A query returns different results before and after a
  concurrent insert.

## Example: Concurrent Account Operations

Two branches both deposit to and withdraw from a shared account:

```elixir
defmodule AccountModel do
  @behaviour PropertyDamage.Model

  def commands do
    [
      {CreateAccount, weight: 2},
      {Deposit, weight: 3, when: &has_accounts?/1},
      {Withdraw, weight: 3, when: &has_accounts?/1},
      {Transfer, weight: 2, when: &has_two_accounts?/1}
    ]
  end

  def command_sequence_projection, do: AccountState

  def assertion_projections, do: [BalanceInvariant]

  defp has_accounts?(state), do: map_size(state.accounts) > 0
  defp has_two_accounts?(state), do: map_size(state.accounts) >= 2
end

defmodule BalanceInvariant do
  use PropertyDamage.Model.Projection

  def init, do: %{deposits: 0, withdrawals: 0, observed_balance: 0}

  def apply(state, %Deposited{amount: amt}) do
    %{state | deposits: state.deposits + amt}
  end

  def apply(state, %Withdrawn{amount: amt}) do
    %{state | withdrawals: state.withdrawals + amt}
  end

  def apply(state, _event), do: state

  @trigger every: :command
  def assert_balance_consistent(state, _event) do
    expected = state.deposits - state.withdrawals

    if state.observed_balance != expected do
      PropertyDamage.fail!(
        "balance mismatch",
        expected: expected,
        observed: state.observed_balance
      )
    end
  end
end
```

Run with parallel branches:

```elixir
PropertyDamage.run(
  model: AccountModel,
  adapter: AccountApiAdapter,
  max_runs: 200,
  branching: [
    max_branches: 2,
    max_branch_length: 4,
    min_prefix_length: 2
  ]
)
```

A non-linearizable result means the final balance does not match any valid
ordering of the concurrent operations -- evidence of a concurrency bug in the
SUT.

## When to Use

Use parallel testing when:

- Your SUT handles concurrent requests (web APIs, databases, message queues).
- You suspect race conditions in shared-state operations.
- You want to verify serializability or linearizability guarantees.

Skip parallel testing for:

- Purely sequential systems with no concurrent access.
- Early development when the basic sequential model is not yet stable.
- Commands that have no shared state interactions.

## Combining with Stutter Testing

Parallel and stutter testing compose. Enable both to test concurrent
idempotency:

```elixir
PropertyDamage.run(
  model: AccountModel,
  adapter: AccountApiAdapter,
  branching: [max_branches: 2, max_branch_length: 4],
  stutter: [probability: 0.2, max_repeats: 1]
)
```

This tests both linearizability of concurrent operations and idempotency of
retried commands within each branch.
