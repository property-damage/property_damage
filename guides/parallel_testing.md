# Parallel Testing and Linearization

PropertyDamage models concurrent operations as parallel branches to expose race
conditions. It executes each branch over a shared adapter context, then checks
whether the observed results are linearizable -- explainable by some valid
sequential ordering. The concurrency is what the checker reasons about; the
branches themselves are executed sequentially (see below).

## Why Parallel Testing

Sequential tests miss timing-dependent bugs. A `Transfer` command that reads a
balance, computes the new value, and writes it back may work perfectly in
isolation but lose updates under concurrency. Parallel testing surfaces these
defects by checking whether the observed results could have arisen only from an
illegal interleaving.

## Branching Sequences

A parallel test sequence has three parts:

```
Prefix (sequential setup):
  CreateAccount{name: "a"} -> CreateAccount{name: "b"}
    (produce account_a, account_b as server-generated ids)

Branches (parallel execution):
  Branch 1: Deposit{acc: account_a, amount: 100} -> Withdraw{acc: account_a, amount: 30}
  Branch 2: Deposit{acc: account_b, amount: 200} -> Transfer{from: account_a, to: account_b, amount: 50}

Suffix (optional sequential cleanup):
  CloseAccount{id: account_a} -> CloseAccount{id: account_b}
```

The **prefix** runs first to establish state. Each **branch** then executes
sequentially, forked from that same post-prefix state and sharing the adapter
context -- the framework does not physically run branches at the same time.
Concurrency is what the linearization checker *models* afterward (it asks whether
the observed per-branch results are explainable by some interleaving), not how
the branches are executed. The **suffix** runs after all branches complete.

Here `account_a` and `account_b` are **placeholders**: stand-ins for the
server-generated account ids that the prefix's `CreateAccount` commands produce.
Fields marked with `external()` in an event struct become placeholders during
generation and are resolved to real values during execution (see
[Writing Commands](writing_commands.md) for the full `external()` lifecycle).
Which placeholders a command may consume depends on where it sits in the
prefix/branch/suffix structure.

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

### Placeholder Scoping

The generator enforces placeholder isolation across the three sections, so a
command can only consume placeholders that are actually in scope at its position:

- Placeholders produced in the **prefix** can be used in **any branch** (every
  branch is generated from the post-prefix state).
- Placeholders produced in **one branch** CANNOT be used in **another branch**
  (branches are generated independently from the same post-prefix snapshot, so
  they never see each other's values).
- Placeholders produced in **branches** CAN be used in the **suffix**, which runs
  after all branches merge (the suffix is generated from the merged post-branch
  state).

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
