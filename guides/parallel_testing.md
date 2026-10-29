# Parallel Testing and Linearization

PropertyDamage generates branching sequences: a prefix, two or more branches
and a suffix. It executes the branches one after another on one adapter
context, then checks whether the observed results are linearizable: explainable
by some ordering of the branch commands that keeps each branch's own order. The
branches never overlap at the system under test, so this path detects no race.
What it checks is that the system's observed events, under some such ordering,
match what the model's simulator predicts, and that every step check passes.

## Why Branching Sequences

A system called one command at a time can still disagree with its model about
what a command does after other commands have run. The linearization checker
asks whether any ordering of the branch commands explains the observed events
against the simulator; when none does, the system and the model disagree.

What it does not do is find timing-dependent bugs. A `Transfer` command that
reads a balance, computes the new value and writes it back loses updates only
when two calls overlap, and no two calls overlap here. Race detection waits for
the concurrent redesign (DR-053); until then a `branching:` run is a check of
the model's predictions under reordering, not a concurrency test.

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
  targets: [MyAdapter],
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
    # No ordering explains the observed events against the simulator
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

## What It Checks

A branching run passes when some interleaving of the branch commands, keeping
the order inside each branch, has every command's observed events contain the
simulator's predicted events (fields that are `nil`, placeholders or external
markers are wildcards) and every step-triggered `@check` pass. The executed
order is the first candidate the checker tries, so a system that behaves
correctly when called one command at a time passes at once. A failure means no
such ordering exists: the system reported something the model never predicts.

## Limits

These hold until the concurrent redesign (DR-053) and are not defects of your
model:

- **No race is detected.** Branches run one after another on one adapter
  context. A lost update, a dirty read or a write-write conflict needs two
  calls to overlap, and none do.
- **`{:indeterminate, _}` passes.** Without a simulator, or when the candidate
  cap is reached before a consistent ordering is found, the run is recorded as
  indeterminate and passes.
- **Any ordering counts.** A sequential defect that another ordering explains
  is accepted: a read that returned `nil` after a physically earlier write is
  taken as "read first". The linear engine, with checks on, reports it.
- **No `@eventually` poller for a branch command.** Checks are off inside the
  branches; the synchronous checks run after the branch set.
- **A converted replay cannot re-execute branch placeholders.** A replay
  artifact of a failure found on this path and converted to linear cannot
  re-execute placeholders minted in a branch (DR-050).
- **Branches are generated from the post-prefix state and judged in reading
  order.** The generator builds every branch from the same state; the executor
  and the shrinker judge the branches one after another, so a generated run
  can fail its own checks in the second branch.
- **`latency:` and a `check_mode:` other than the default are option errors**
  beside `branching:`: the path records no latency samples and halts at the
  first failing check.

## Example: Concurrent Account Operations

> This example highlights only the branching wiring. The `CreateAccount` /
> `Deposit` / `Withdraw` / `Transfer` commands, their events, and
> `AccountApiAdapter` are assumed; define them following
> [Writing Commands](writing_commands.md) and [Getting Started](getting_started.md).

Two branches both deposit to and withdraw from a shared account:

```elixir
defmodule AccountModel do
  use PropertyDamage.Model

  def commands do
    [
      {CreateAccount, weight: 2},
      {Deposit, weight: 3, when: &has_accounts?/1},
      {Withdraw, weight: 3, when: &has_accounts?/1},
      {Transfer, weight: 2, when: &has_two_accounts?/1}
    ]
  end

  def command_sequence_projection, do: AccountState

  def check_projections, do: [BalanceInvariant]

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

  @check every: :command
  def assert_balance_consistent(state, _event) do
    expected = state.deposits - state.withdrawals

    state.observed_balance == expected or
      PropertyDamage.fail!("balance mismatch",
        expected: expected,
        observed: state.observed_balance
      )
  end
end
```

Run with parallel branches:

```elixir
PropertyDamage.run(
  model: AccountModel,
  targets: [AccountApiAdapter],
  max_runs: 200,
  branching: [
    max_branches: 2,
    max_branch_length: 4,
    min_prefix_length: 2
  ]
)
```

A non-linearizable result means no ordering of the branch commands that keeps
each branch's order explains the observed events against the simulator: a
disagreement between the system and the model, not evidence of a race.

## When to Use

Use branching sequences when:

- Your model has a simulator and you want its predictions checked against the
  observed events under reordering.
- You want the prefix, branch and suffix generation shape, with its placeholder
  scoping, exercised against your model.

Do not use them to find races: the branches do not overlap. Skip them for:

- Early development when the basic sequential model is not yet stable.
- Commands that have no shared state interactions.

## Branches Are Not Several Targets

Parallel branches run against one target. `branching:` with two or more
`targets:` is an option error. Comparing several targets is a different feature
(see [Differential Testing](differential_testing.md)): its `concurrency:
:parallel` option makes the targets advance at the same time, and has nothing to
do with parallel branches.

## Combining with Stutter Testing

Parallel and stutter testing compose. Enable both to test concurrent
idempotency:

```elixir
PropertyDamage.run(
  model: AccountModel,
  targets: [AccountApiAdapter],
  branching: [max_branches: 2, max_branch_length: 4],
  stutter: [probability: 0.2, max_repeats: 1]
)
```

This tests both linearizability of concurrent operations and idempotency of
retried commands within each branch.
