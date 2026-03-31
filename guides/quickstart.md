# Quickstart for Property-Based Testing Veterans

This guide is for developers already familiar with stateful property-based testing
(QuickCheck, PropEr, Hypothesis). It maps concepts you already know to
PropertyDamage's architecture and gets you running fast.

## Core Concepts Mapping

| QuickCheck / PropEr | PropertyDamage | Notes |
|---------------------|----------------|-------|
| `state_machine` / `statem` | **Model** | Orchestrates commands, weights, preconditions |
| `command` (generator + precondition) | **Command** (pure generator only) | No state dependency in Command; state logic lives in Model |
| `postcondition` | **Projection** + `@trigger` assertions | Event-driven, not return-value-driven |
| `next_state` | **Projection** `apply/2` + **Simulator** | Projections reduce events; Simulator predicts events during generation |
| `precondition` | Model's `when:` predicate | Declared per-command in `commands/0` |
| `initial_state` | Projection `init/0` | Each projection has its own initial state |
| `run_commands` | `PropertyDamage.run/1` | Generates, executes, and shrinks automatically |
| Shrinking (automatic) | Two-phase shrinking | Sequence shrinking first, then argument simplification |

## Key Differences

**Event-based, not state-mutation-based.** Commands produce events, events flow
through projections. There is no direct `next_state(State, Result, Call)` function.
Instead:

```
Command -> Adapter.execute/2 -> {:ok, [events]} -> Projection.apply/2 -> new state
```

**Commands are transport-agnostic.** A `CreateOrder` command is a pure data
generator. The same command struct works whether your adapter sends HTTP requests,
gRPC calls, or direct function calls. The Model defines WHAT and WHEN. The
Adapter defines HOW.

**Separate generation and execution phases.** During generation, a Simulator
predicts events so projections can build state for preconditions and overrides.
During execution, real events from the SUT replace predictions.

**Assertions are projection-based.** Instead of postconditions on return values,
you define projections with `@trigger` attributes that fire assertions at
configurable intervals (every step, every N commands, on specific event types).

## Minimal Example

```elixir
# --- Event ---
defmodule AccountCreated do
  import PropertyDamage, only: [external: 0]
  defstruct [id: external(), :name]
end

# --- Command ---
defmodule CreateAccount do
  use PropertyDamage.Command

  defstruct [:name]

  @impl true
  def generator(overrides \\ %{}) do
    %{name: StreamData.string(:alphanumeric, min_length: 1, max_length: 20)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

# --- Projection (state tracking + assertion) ---
defmodule AccountState do
  use PropertyDamage.Model.Projection

  def init, do: %{accounts: %{}}

  def apply(state, %AccountCreated{id: id, name: name}) do
    put_in(state, [:accounts, id], %{name: name})
  end
  def apply(state, _), do: state

  @trigger every: 1
  def assert_no_duplicate_names(state, _) do
    names = state.accounts |> Map.values() |> Enum.map(& &1.name)
    if length(names) != length(Enum.uniq(names)) do
      PropertyDamage.fail!("duplicate account names", names: names)
    end
  end
end

# --- Simulator ---
defmodule AccountSimulator do
  @behaviour PropertyDamage.Model.Simulator

  def simulate(%CreateAccount{name: name}, _state) do
    [%AccountCreated{name: name}]
  end
  def simulate(_, _), do: []
end

# --- Model ---
defmodule AccountModel do
  @behaviour PropertyDamage.Model

  @impl true
  def commands, do: [CreateAccount]

  @impl true
  def command_sequence_projection, do: AccountState

  @impl true
  def assertion_projections, do: [AccountState]

  @impl true
  def simulator, do: AccountSimulator
end

# --- Adapter ---
defmodule AccountAdapter do
  use PropertyDamage.Adapter

  @impl true
  def setup(_config), do: {:ok, %{}}

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%CreateAccount{name: name}, _ctx) do
    id = "acc_#{System.unique_integer([:positive])}"
    {:ok, [%AccountCreated{id: id, name: name}]}
  end
end
```

Run it:

```elixir
PropertyDamage.run(
  model: AccountModel,
  adapter: AccountAdapter,
  max_commands: 20,
  max_runs: 50
)
```

## Ref Flow

Refs are symbolic placeholders for server-generated IDs. They are created during
generation and resolved during execution.

```
Generation (symbolic phase):
  CreateAccount{name: "alice"}  ->  AccountCreated{id: #Ref<0>, name: "alice"}
  GetBalance{account: #Ref<0>}  (references the account created above)

Execution (concrete phase):
  CreateAccount{name: "alice"}  ->  AccountCreated{id: "acc_123", name: "alice"}
  GetBalance{account: "acc_123"} (ref resolved to real value)
```

Fields marked with `external()` in event structs are automatically detected.
During generation, the framework assigns a symbolic `#Ref<N>`. During execution,
the real value from the SUT replaces the ref wherever it appears in subsequent
commands.

## IEx Helpers

Import `PropertyDamage.IEx` for interactive exploration:

```elixir
import PropertyDamage.IEx

# Inspect model structure: commands, projections, weights, hints
explain(AccountModel)

# Generate a command sequence without executing (preview what would run)
dry_run(AccountModel, commands: 10)

# Execute a single command with detailed output
debug_command(%CreateAccount{name: "test"}, AccountAdapter)

# Show projection state after applying a list of events
inspect_state(AccountState, [%AccountCreated{id: "1", name: "alice"}])

# See which commands are valid given a state
check_preconditions(AccountModel, %{accounts: %{"1" => %{name: "alice"}}})
```

## Run Configurations

```elixir
# Basic
PropertyDamage.run(model: M, adapter: A)

# Seeded (reproducible)
PropertyDamage.run(model: M, adapter: A, seed: 42)

# Parallel / branching (race condition detection)
PropertyDamage.run(
  model: M,
  adapter: A,
  branching: [
    branch_probability: 0.3,
    max_branches: 3,
    max_branch_length: 5
  ]
)

# Stutter / idempotency testing
PropertyDamage.run(
  model: M,
  adapter: A,
  stutter: %{
    probability: 0.2,
    max_repeats: 3,
    delay_ms: {10, 200}
  }
)

# Load test
PropertyDamage.run(
  model: M,
  adapter: A,
  max_commands: 500,
  max_runs: 1000,
  verbose: true
)

# Chaos / fault injection
PropertyDamage.run(
  model: M,
  adapter: A,
  nemesis: [PartitionNetwork, InjectLatency]
)
```
