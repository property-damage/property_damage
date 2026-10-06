# Writing Commands

Commands are semantic operations that can be executed against the System Under Test (SUT). They define WHAT can happen, while Adapters define HOW it happens against specific targets.

## Command Architecture

Commands follow a pure generator pattern - they are decoupled from state shape and reusable across different Models.

> **Generators must be a pure function of the seed.** A generator that reads the
> clock, `:rand`, `System.unique_integer/1`, or `UUID.uuid4/0` breaks `seed: N`
> reproduction and run comparison. Model time, client-minted ids, and
> server-assigned ids with the three seams in the
> [deterministic generation guide](deterministic_generation.md), and enforce it
> with `mix pd.audit`.

### Command Responsibilities

Commands define:
- **Struct fields** - The data needed for the operation
- **`generator/1`** - How to generate valid field values
- **Static metadata** - declared on the single `command_spec/1` surface (via `use`
  options): `execution`, `shrink`, `observables`, `idempotent`, ...

Commands do NOT define:
- When the command is valid (preconditions) - defined in Model via `when:`
- How to parameterize based on state - defined in Model via `overrides:`
- Expected events from execution - defined in Model via `simulate/2`

### Basic Command Example

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyTest.Commands.CreateOrder do
  # Events this command can produce are declared on the command_spec surface.
  use PropertyDamage.Command, observables: [MyTest.Events.OrderCreated, MyTest.Events.OrderRejected]
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount, :currency]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      amount: StreamData.positive_integer(),
      currency: StreamData.member_of(["USD", "EUR", "GBP"])
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

# The corresponding event marks server-generated fields with external()
defmodule MyTest.Events.OrderCreated do
  import PropertyDamage, only: [external: 0]

  # order_id is server-generated, amount and currency come from the command
  defstruct [:amount, :currency, order_id: external()]
end

# The other events referenced by observables and the simulate/2 clauses below.
defmodule MyTest.Events.OrderRejected do
  defstruct [:reason]
end

defmodule MyTest.Events.OrderViewed do
  defstruct [:order_ref]
end

defmodule MyTest.Events.OrderNotFound do
  defstruct [:order_ref]
end
```

### State-Dependent Command Example

For commands that need state-dependent values (like selecting from existing refs):

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyTest.Commands.ViewOrder do
  # Read-only commands set shrink: :prefer_remove so they are pruned first.
  use PropertyDamage.Command,
    shrink: :prefer_remove,
    observables: [MyTest.Events.OrderViewed, MyTest.Events.OrderNotFound]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:order_ref]

  @impl true
  def generator(overrides \\ %{}) do
    # Default to nil - Model provides actual refs via overrides:
    %{order_ref: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end
```

The Model wires this command with state:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyTest.OrderModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias MyTest.Commands.{CreateOrder, ViewOrder}
  alias MyTest.Events.{OrderViewed, OrderNotFound}

  def commands do
    [
      CreateOrder,
      {ViewOrder,
        when: fn s -> map_size(s.orders) > 0 end,
        overrides: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
    ]
  end

  def command_sequence_projection, do: MyTest.OrderProjection

  # Return self as the simulator module
  def simulator, do: __MODULE__

  # simulate/2 defines expected events (Simulator behaviour)
  def simulate(%ViewOrder{order_ref: ref}, state) do
    if Map.has_key?(state.orders, ref) do
      [%OrderViewed{order_ref: ref}]
    else
      [%OrderNotFound{order_ref: ref}]
    end
  end
end
```

## Server-Generated Values

When a command creates a new entity (e.g., CreateOrder produces an order with a
server-generated ID), the framework needs to pass that ID to future commands. The
`external()` marker solves this "chicken-and-egg" problem.

### Why Placeholders Exist

During sequence generation, the SUT hasn't been contacted yet — there are no real IDs.
The framework mints placeholders for server-generated fields and resolves them to real
values during execution.

### External Field Markers

Mark server-generated fields in event structs with `external()`:

    defmodule OrderCreated do
      import PropertyDamage, only: [external: 0]
      defstruct [:amount, :currency, id: external()]
    end

The framework detects external fields automatically and captures their values during
execution.

### Lifecycle

    Generation phase:
      CreateOrder{amount: 100}       →  OrderCreated{id: <placeholder>}
      GetOrder{order_ref: <placeholder>}

    Execution phase:
      CreateOrder{amount: 100}       →  OrderCreated{id: "ord_abc123"}
      GetOrder{order_ref: "ord_abc123"}  ← placeholder resolved from event

1. **Generation**: each `external()` field in a simulated event becomes a `%Placeholder{}`
2. **Simulation**: the simulator predicts events carrying those placeholders
3. **State tracking**: projections store the placeholder as a value
4. **Execution**: after the adapter returns (or injects) real events, the framework
   captures the concrete value from each `external()` field by the producer's position
5. **Resolution**: subsequent commands have their placeholder fields replaced with the
   concrete values

### Dependency-Aware Shrinking

The shrinker respects placeholder dependencies: if command A produces a value consumed by
command B, command A cannot be removed while B remains in the sequence.

## Model-Level Wiring

All state-dependent configuration lives in the Model:

### Command Specification Options

```elixir
def commands do
  [
    # Simple: always enabled, weight 1
    CreateOrder,

    # Weighted: {module, weight: n}
    {CreateOrder, weight: 3},

    # Full options
    {ViewOrder,
      weight: 2,
      when: fn state -> map_size(state.orders) > 0 end,
      overrides: fn state -> %{order_ref: StreamData.member_of(Map.keys(state.orders))} end}
  ]
end
```

| Option | Type | Description |
|--------|------|-------------|
| `weight:` | `pos_integer()` | Relative selection frequency (default: 1) |
| `when:` | `(state -> boolean)` | Precondition function |
| `overrides:` | `(state -> map)` | Override function for generation |

### Simulate Callback

> **State-dependent commands require a simulator.** During *generation* there is no
> SUT, so projection state is built only from the events a simulator predicts. A
> command whose `when:`/`overrides:` reads that state (e.g. "select an existing account")
> will see the empty initial state and **never be selected** unless a `simulator/0`
> populates the state first. If your `when:`/`overrides:` commands mysteriously never fire,
> a missing simulator is the usual cause.

Models that need symbolic execution implement the `PropertyDamage.Model.Simulator` behaviour
and return themselves (or a delegate module) via `simulator/0`:

```elixir
defmodule MyTest.OrderModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  def commands, do: [CreateOrder, CancelOrder]
  def command_sequence_projection, do: MyTest.OrderProjection
  def check_projections, do: []

  # Return self as the simulator module
  def simulator, do: __MODULE__

  # Simulator behaviour callback
  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateOrder{amount: amount}, _state) do
    [%OrderCreated{amount: amount, order_ref: nil}]
  end

  def simulate(%CancelOrder{order_ref: ref}, state) do
    if Map.has_key?(state.orders, ref) do
      [%OrderCancelled{order_ref: ref}]
    else
      [%OrderNotFound{order_ref: ref}]
    end
  end

  # Catch-all for commands with no events
  def simulate(_command, _state), do: []
end
```

## Setup and Teardown Commands

A fixture is a command. If every run needs a user who is logged in, the model
says so in `setup_each/0`, and each target's adapter decides how to do it.
Two optional callbacks, both defaulting to `[]`, carry the fixtures:

| Callback | Runs | Returns |
|----------|------|---------|
| `setup_each/0` | before the first root of every run and every shrink attempt | the setup commands |
| `teardown_each/0` | after the last root and the final checks | the teardown commands |

Both return what `commands/0` accepts (`Module` or `{Module, opts}`, with
`overrides:`). A **root** is a command the generator draws from `commands/0`.
Setup and teardown commands are not roots, and the model performs no side effect.

### Example: a Login Per Target

Take a notes service. Every note belongs to a logged-in user, and the targets
log in differently: one uses OAuth, the other Basic auth. Only the adapter
knows how, so the model lists `CreateUser` and `Login` as setup commands, and
`Login` uses the id the server assigned to the user:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Notes.Events do
  defmodule UserCreated do
    import PropertyDamage, only: [external: 0]
    defstruct [:name, user_id: external()]
  end

  defmodule LoggedIn do
    defstruct [:user_id]
  end

  defmodule NoteAdded do
    defstruct [:user_id, :text]
  end
end

defmodule Notes.Commands do
  defmodule CreateUser do
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:name]

    @impl true
    def generator(overrides \\ %{}) do
      %{name: StreamData.string(:alphanumeric, min_length: 1)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Login do
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:user_id]

    @impl true
    def generator(overrides \\ %{}) do
      # The model fills in user_id from the setup state.
      %{user_id: nil}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule AddNote do
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:user_id, :text]

    @impl true
    def generator(overrides \\ %{}) do
      %{user_id: nil, text: StreamData.string(:alphanumeric, min_length: 1)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
end

defmodule Notes.Session do
  use PropertyDamage.Model.Projection

  alias Notes.Events.{LoggedIn, NoteAdded, UserCreated}

  @impl true
  def init, do: %{user: nil, logged_in: false, notes: 0}

  @impl true
  def apply(state, %UserCreated{user_id: id}), do: %{state | user: id}
  def apply(state, %LoggedIn{}), do: %{state | logged_in: true}
  def apply(state, %NoteAdded{}), do: %{state | notes: state.notes + 1}
  def apply(state, _event), do: state

  # Both targets must hold the same number of notes after every root.
  @compare every: 1
  def note_count(state, _root), do: state.notes
end

defmodule Notes.Model do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias Notes.Commands.{AddNote, CreateUser, Login}
  alias Notes.Events.{LoggedIn, NoteAdded, UserCreated}

  # The setup commands run in this order, every one, before the first root.
  @impl true
  def setup_each do
    [
      {CreateUser, overrides: %{name: "fixture"}},
      {Login, overrides: fn state -> %{user_id: state.user} end}
    ]
  end

  # The roots see the fixture state: AddNote needs the logged-in user.
  @impl true
  def commands do
    [
      {AddNote,
       when: fn state -> state.logged_in end,
       overrides: fn state -> %{user_id: state.user} end}
    ]
  end

  @impl true
  def command_sequence_projection, do: Notes.Session

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateUser{name: name}, _state), do: [%UserCreated{name: name}]
  def simulate(%Login{user_id: id}, _state), do: [%LoggedIn{user_id: id}]
  def simulate(%AddNote{user_id: id, text: text}, _state), do: [%NoteAdded{user_id: id, text: text}]
end
```

Each adapter realizes `Login` its own way. The OAuth adapter fetches a token
and keeps it in its context. The Basic-auth adapter does nothing for `Login`
and sends credentials with every call:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Notes.OAuthAdapter do
  use PropertyDamage.Adapter

  alias Notes.Commands.{AddNote, CreateUser, Login}
  alias Notes.Events.{LoggedIn, NoteAdded, UserCreated}

  @impl true
  def setup(_config) do
    {:ok, tokens} = Agent.start_link(fn -> %{} end)
    {:ok, %{tokens: tokens}}
  end

  @impl true
  def teardown(%{tokens: tokens}) do
    Agent.stop(tokens)
    :ok
  end

  @impl true
  def execute(%CreateUser{name: name}, _ctx, _runtime),
    do: {:ok, [%UserCreated{name: name, user_id: "oauth-user-1"}]}

  # Only this adapter knows login means fetching a token.
  def execute(%Login{user_id: id}, %{tokens: tokens}, _runtime) do
    Agent.update(tokens, &Map.put(&1, id, "token-for-#{id}"))
    {:ok, [%LoggedIn{user_id: id}]}
  end

  def execute(%AddNote{user_id: id, text: text}, %{tokens: tokens}, _runtime) do
    case Agent.get(tokens, &Map.get(&1, id)) do
      nil -> {:error, :unauthorized}
      _token -> {:ok, [%NoteAdded{user_id: id, text: text}]}
    end
  end
end

defmodule Notes.BasicAdapter do
  use PropertyDamage.Adapter

  alias Notes.Commands.{AddNote, CreateUser, Login}
  alias Notes.Events.{LoggedIn, NoteAdded, UserCreated}

  @impl true
  def setup(_config), do: {:ok, %{}}

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%CreateUser{name: name}, _ctx, _runtime),
    do: {:ok, [%UserCreated{name: name, user_id: "basic-user-1"}]}

  # Basic auth has no session: logging in has nothing to do.
  def execute(%Login{user_id: id}, _ctx, _runtime), do: {:ok, [%LoggedIn{user_id: id}]}

  def execute(%AddNote{user_id: id, text: text}, _ctx, _runtime),
    do: {:ok, [%NoteAdded{user_id: id, text: text}]}
end

{:ok, stats} =
  PropertyDamage.run(
    model: Notes.Model,
    targets: [{Notes.OAuthAdapter, name: "oauth"}, {Notes.BasicAdapter, name: "basic"}],
    max_runs: 5,
    max_commands: 6,
    seed: 1
  )

# The stats count setup commands apart from the roots: two per run.
true = stats.setup_commands == 2 * stats.runs
```

The two targets mint different user ids, and neither id is compared:
`Notes.Session.note_count/2` is the only observation.

### Rules for a Setup List

A setup list is a sequence, not a pick list. The same holds for a teardown list.

- Every entry runs, in the order written. There is no `when:` filter and no
  weighted draw. A `when:` or `weight:` on an entry draws a `mix pd.validate`
  warning ("ignored in a sequence").
- `terminate_early?/3` and `max_commands` apply to roots only.
- A setup command is not a root. It is never compared (the end of the setup
  commands is no boundary, and a `@compare every: Login` does not fire on a
  setup `Login`), never expanded, and never dropped, reordered or simplified
  by the shrinker. A module can appear in both `setup_each/0` and `commands/0`,
  and each entry follows its own rules.
- The engine keeps placeholder resolution, projections, pollers, injectors,
  the per-command settle and retry, and checks on during setup commands.
  Stutter and nemesis faults are off, because they would test the fixture
  instead of the property, so a nemesis module in either callback is a
  validation error. No latency sample is recorded for a setup command.
- Sampling counters (`every: N`) start at the first root: setup commands never
  advance them.

### Seeds and Setup Commands

The generator draws setup commands from the run seed before the roots, and
simulates them first, so each root's `when:` and `overrides:` see the fixture
state. Adding a setup command therefore re-draws the roots for a given seed.
A seed is stable for a fixed model. A model with no setup commands draws what it
always drew.

### When Setup Fails

A setup failure has kind `:setup_failed`, and the report's `failed_at_index` is
`nil`. It has four causes:

| Cause | What happened |
|-------|---------------|
| `:adapter_setup` | `Adapter.setup/1` returned `{:error, _}` or raised |
| `:command` | a setup command answered `{:error, _}` or raised |
| `:check` | a `@check` or `@eventually` check failed on a setup command's event |
| `:unresolved_placeholder` | an `external()` a setup command produced was still unresolved after the last setup command |

The last cause includes a command whose adapter answered with a different
event than the simulator predicted: the predicted event, and its id, never
arrives. `PropertyDamage.Failure.Setup` carries `cause`, `command`,
`setup_index`, `field` and `detail`.

A check that fails on a setup command's event is a setup failure wherever it is
detected. That includes an `@eventually` window a setup command's event opened,
if it times out after the roots started.

With several targets, the reference is the first one:

- A setup failure in the reference ends the run before any root.
- A setup failure in another target, found before the first root, retires that
  target alone. The others go on, and the run ends when only the reference is
  left. The one setup failure found later, an `@eventually` window that a setup
  command opened and that times out after the first root, ends the run.

The shrinker never shrinks a setup failure. During shrinking, an attempt in which
a setup command failed is not a reproduction, so the shrinker rejects that
candidate and counts the attempt.

### Teardown Commands

Teardown commands run after every execution of a target: after a pass, after a
failure, after a setup failure, and after the target is retired. They run
before `Adapter.teardown/1`, and not for a target whose `Adapter.setup/1`
failed, because no adapter context exists. The generator draws them after the
last root, against the state that root left, so their `overrides:` can name
anything the run created. See
[Integration Testing](integration_testing.md#cleaning-up-a-shared-target) for an
example.

Teardown is best effort. A teardown command whose placeholder never resolved is
skipped with a warning, and an error or a raise is logged. Neither changes the
verdict.

### Where Other Setup Belongs

- **Infrastructure reset** (wiping a table, starting a pool) belongs in
  `Adapter.setup/1`, not in a command. It runs before every run, shrink attempt
  and replay, in every target, so it must be idempotent: it can find what a
  crashed run left. The runner calls it for one target after another and
  finishes all of them before any target executes a command.
- **Isolation between targets** is the target's `config:`. When two targets share
  one system, the generated values (fixtures included) are shared too, so give
  each target a tenant, an account or a path prefix in its `config:`.
  `mix pd.validate` warns about two targets that use the same adapter with an
  identical `config:`.
- **Once per campaign** has no callback. A once-per-campaign fixture is deferred
  until a model has one too slow to run per run. Until then, make `Adapter.setup/1`
  idempotent, or wrap `PropertyDamage.run/1` in your own function.

The earlier side-effect lifecycle hooks no longer exist. A model that still
defines one fails at run start with an error that names the replacement.

## Expansions: One Root, Several Commands

Some operations have more than one way to be done. A counter can add 5 in one
call or add 3 and then add 2. A payment can be one `Pay` call or `Authorize`
then `Capture`. If the model says that the ways mean the same, each target can
run a different way, and a disagreement between the targets is a bug in one of
the ways.

The optional callback `expansions/0` lists the ways. Its contract is one
sentence: **every expansion of a root means the same as the root once the root
is done, under every `@compare` value of the model.** A rewrite that does not
meet it under the model's observations is not an expansion of that model, so
either stop observing the field that differs or leave the rewrite out.

The vocabulary: a **root command** is a module that `commands/0` lists. A
**root** is one occurrence of it in the generated sequence. An **expansion** is
one command sequence the model lists for it, and the root run as itself is the
**identity**. A **leaf** is a command that a target executes for an expanded
root.

### Example: Increment by Parts

A counter service keeps one integer per key. The model has one command, `Incr`,
and says that `Incr k 5` may also run as two increments of the same key that
add up to 5:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Counter.Events do
  defmodule Incremented do
    defstruct [:key, :amount]
  end
end

defmodule Counter.Commands do
  defmodule Incr do
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:key, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{key: StreamData.member_of(["a", "b"]), amount: StreamData.integer(1..10)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
end

defmodule Counter.Totals do
  use PropertyDamage.Model.Projection

  alias Counter.Events.Incremented

  @impl true
  def init, do: %{}

  @impl true
  def apply(totals, %Incremented{key: key, amount: amount}),
    do: Map.update(totals, key, amount, &(&1 + amount))

  def apply(totals, _event), do: totals

  # Every target must hold the same totals after every root.
  @compare every: 1
  def totals(state, _root), do: state
end

defmodule Counter.Model do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias Counter.Commands.Incr
  alias Counter.Events.Incremented

  @impl true
  def commands, do: [Incr]

  @impl true
  def command_sequence_projection, do: Counter.Totals

  # The roots that have expansions, each with a function of the root and the
  # simulated state. The function returns a plain list of entries.
  @impl true
  def expansions, do: [{Incr, &incr_expansions/2}]

  # The identity comes first: it is the simplest entry, and the shrink
  # preference follows the list order. Its weight is 2, the rewrite's is 1.
  def incr_expansions(%Incr{key: key, amount: amount} = incr, _state) do
    [{[incr], weight: 2} | split(key, amount)]
  end

  # `Incr k 1` has no rewrite. For a larger amount, the first leaf adds half and
  # the second takes the rest from the first leaf's event (the arity-2 form of
  # `overrides:`, legal only inside an expansion sequence).
  defp split(_key, amount) when amount < 2, do: []

  defp split(key, amount) do
    [
      [
        {Incr, overrides: %{key: key, amount: div(amount, 2)}},
        {Incr,
         overrides: fn _state, [%{events: [%Incremented{amount: first}]}] ->
           %{key: key, amount: amount - first}
         end}
      ]
    ]
  end

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%Incr{key: key, amount: amount}, _state),
    do: [%Incremented{key: key, amount: amount}]
end

defmodule Counter.Adapter do
  use PropertyDamage.Adapter

  alias Counter.Commands.Incr
  alias Counter.Events.Incremented

  @impl true
  def setup(_config) do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    {:ok, %{agent: agent}}
  end

  @impl true
  def teardown(%{agent: agent}) do
    Agent.stop(agent)
    :ok
  end

  @impl true
  def execute(%Incr{key: key, amount: amount}, %{agent: agent}, _runtime) do
    Agent.update(agent, &Map.update(&1, key, amount, fn total -> total + amount end))
    {:ok, [%Incremented{key: key, amount: amount}]}
  end
end

{:ok, stats} =
  PropertyDamage.run(
    model: Counter.Model,
    targets: [
      {Counter.Adapter, name: "direct", expansion: :identity},
      {Counter.Adapter, name: "split"}
    ],
    max_runs: 20,
    max_commands: 10,
    seed: 1
  )

# "direct" runs the roots themselves and counts nothing. "split" picked an
# entry at every `Incr`; both entries came up in these 20 runs.
%{"direct" => direct, "split" => %{Counter.Commands.Incr => entries}} = stats.expansion_counts
true = direct == %{}
true = entries["Incr[0]"] > 0 and entries["Incr[1]"] > 0
```

Two targets on one adapter module are two independent counters, because
`setup/1` starts a new agent per target. The first target runs the roots (the
simple path) and the second runs a rewrite where it picked one. After every
root the framework compares `Counter.Totals.totals/2` of the two. A bug in
the adapter that mishandles an amount below 3 would show up in "split" at the
root that chose `Incr[1]`, because the rewrite sends such an amount.

### The Entries

- **A list of entries.** `fun` receives the root as generated and the target's
  simulated state at that root, and returns a plain list. An entry is a
  sequence, or `{sequence, weight: n}` with `n` a positive integer. The default
  weight is 1.
- **The identity is listed.** Write the received struct alone, as `[incr]` or
  `{[incr], weight: 2}`. Nothing is chosen that the function did not list. The
  struct may appear nowhere else in a sequence.
- **A sequence is a list of command specs**, the grammar of `commands/0`:
  `Module` or `{Module, opts}`. `overrides:` is a map, a function of the state, or
  (inside a sequence only) a function of the state and the earlier leaves. In
  `commands/0`, `setup_each/0` and `teardown_each/0` an arity-2 function is a load
  error.
- **The earlier leaves** reach the arity-2 function as
  `%{command: leaf, events: simulated events}`, with `external()` fields as
  placeholders. A value taken from a sibling's event is therefore the
  sibling's placeholder, and each target resolves it from its own real events.
- **`when:` and `weight:` on a leaf do nothing.** `mix pd.validate --seeds`
  warns "ignored in a sequence".
- **The order is the shrink preference**, simplest first. The order of
  `commands/0` carries no meaning.
- **Report keys** name an entry by its index and leaves: `Incr[1] = [Incr, Incr]`.
  Reordering the list renames the keys, so keep the order stable once you read
  reports.

### Choosing per Target: `expansion:`

Each target picks its entry per root by its `expansion:` option: `:random` (the
default), `:identity` or `:reference`. The table, and what each mix tests, is in
the [differential testing guide](differential_testing.md#when-the-model-has-expansions).

The `:random` pick is keyed on the run seed, the target's **name** and the root.
Reordering `targets:` therefore changes only which target is the reference.
Renaming a target picks again, so a name is a generation input as a seed is for a
fixed model. A report's `seed` replays its picks: `seed: report.seed, max_runs: 1`
with the same target names runs the same entries.

### Root Placeholders

A later root may consume a value that an earlier root's simulation minted with
`external()`. In a target that ran a rewrite, the framework aliases each such
placeholder to the placeholder of exactly one leaf whose simulated events hold
the same event module at the same field. Zero matches, or several (two leaves,
or two events of one leaf), are a generation error that names the root, the
entry and the candidate leaves. Make the leaves' events agree with the root's
event to fix it.

### When Nothing Fits: "Identity, Forced"

A leaf whose module has a `commands/0` entry with a `when:` that is false at its
position withdraws its entry, and the pick is made again among the rest. When no
entry is left, or the function returns `[]`, the root runs as itself and the run
counts it as `:forced`. A root forced in every sampled state shows in
`mix pd.validate --seeds`.

### Rules at Load

The run stops before any `Adapter.setup/1` when:

- the model defines `expansions/0` and declares no `@compare` that reaches the
  end of the run (`every: 1`, the default, or a schedule that names `:end`). One
  target needs it too;
- `expansions/0` lists a module that `commands/0` does not (a setup or teardown
  command is not a root), lists a module twice, or lists a root with
  `execution: :probe`;
- the run passes `branching:` for a model with `expansions/0`;
- an expansion function has the wrong arity, or raises (the error names the
  root);
- a leaf module lacks the command callbacks (the error names the root, the entry
  and the leaf), or an `overrides:` map names a key the leaf's struct lacks.

Setup and teardown commands are never expanded.

### What Counts

Leaves are ordinary commands: `@check every: Module` fires on a leaf of that
module, `@check every: N` counts steps per target, and latency samples and
coverage count leaves under their own module. Roots are what `@compare`
schedules, `max_commands` and `total_commands` count, and the comparison at root
`r` waits until every target has stepped every leaf of `r`. `terminate_early?/3`
is consulted after roots only.

The run result and the failure report carry `expansion_counts` (per target and
root module, the count per entry and `:forced`). A failure report also carries
`expansions`: per target, one element per root up to the failing root, with the
entry and the leaf modules. A failure's `failed_at_index` stays the root index.

### Shrinking and Reproducing

The shrinker deletes roots and simplifies root arguments, and keeps each
target's entry for every surviving root. It never deletes or simplifies a leaf
on its own, and it does not yet replace one entry with another, so a
reproduction can be larger than the smallest rewrite that fails. A candidate
whose expansion function raises, or stops offering the carried entry for a
simplified root, is dropped. `shrink_further/2`, `Replay` and export run what
each target ran, never a new pick. `Analysis.isolate_trigger/2` raises for a
target that ran leaves.

Check which entries a model's seeds reach before you trust a green run:

```
mix pd.validate Counter.Model --targets "[Counter.Adapter]" --seeds 50
```

The task lists every entry with how often 50 root sequences realized it, and
names the entries it never realized. `--seed S --seeds 1` samples exactly the roots
and entries that `seed: S, max_runs: 1` runs.

## Managing Model Verbosity

With many commands, Models can grow large. Here are patterns to keep them manageable:

### Pattern 1: Helper Modules for Wiring

Factor wiring functions into a helper module:

```elixir
defmodule MyTest.OrderModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias MyTest.CommandWiring
  alias MyTest.Simulation

  def commands do
    [
      {CreateOrder, CommandWiring.create_order()},
      {ViewOrder, CommandWiring.view_order()},
      {CancelOrder, CommandWiring.cancel_order()}
    ]
  end

  def command_sequence_projection, do: MyTest.OrderProjection
  def check_projections, do: []

  # Return self as the simulator (delegates to Simulation module)
  def simulator, do: __MODULE__

  # Delegate simulate/2 to helper module
  defdelegate simulate(command, state), to: Simulation
end

defmodule MyTest.CommandWiring do
  def create_order, do: [weight: 3]

  def view_order do
    [
      weight: 2,
      when: fn s -> map_size(s.orders) > 0 end,
      overrides: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end
    ]
  end

  def cancel_order do
    [
      weight: 1,
      when: fn s -> Enum.any?(s.orders, fn {_, o} -> o.status == :active end) end,
      overrides: fn s ->
        active = Enum.filter(s.orders, fn {_, o} -> o.status == :active end)
        %{order_ref: StreamData.member_of(Keyword.keys(active))}
      end
    ]
  end
end

defmodule MyTest.Simulation do
  @behaviour PropertyDamage.Model.Simulator

  @impl true
  def simulate(%CreateOrder{amount: amount}, _state) do
    [%OrderCreated{amount: amount, order_ref: nil}]
  end

  def simulate(%ViewOrder{order_ref: ref}, _state) do
    [%OrderViewed{order_ref: ref}]
  end

  def simulate(%CancelOrder{order_ref: ref}, _state) do
    [%OrderCancelled{order_ref: ref}]
  end
end
```

### Pattern 2: Shared Wiring Across Models

When multiple Models use the same commands with similar wiring:

```elixir
defmodule SharedWiring.Orders do
  @moduledoc """
  Reusable wiring for order-related commands.
  Parameterized by state key for flexibility.
  """

  def view_order_wiring(orders_key \\ :orders) do
    [
      when: fn s -> map_size(Map.get(s, orders_key, %{})) > 0 end,
      overrides: fn s ->
        orders = Map.get(s, orders_key, %{})
        %{order_ref: StreamData.member_of(Map.keys(orders))}
      end
    ]
  end

  def cancel_order_wiring(orders_key \\ :orders, status_field \\ :status) do
    [
      when: fn s ->
        orders = Map.get(s, orders_key, %{})
        Enum.any?(orders, fn {_, o} -> Map.get(o, status_field) == :active end)
      end,
      overrides: fn s ->
        orders = Map.get(s, orders_key, %{})
        active_refs =
          orders
          |> Enum.filter(fn {_, o} -> Map.get(o, status_field) == :active end)
          |> Enum.map(fn {ref, _} -> ref end)
        %{order_ref: StreamData.member_of(active_refs)}
      end
    ]
  end
end

# Model A uses standard state shape
defmodule ModelA do
  import SharedWiring.Orders

  def commands do
    [
      CreateOrder,
      {ViewOrder, view_order_wiring()},
      {CancelOrder, cancel_order_wiring()}
    ]
  end
end

# Model B uses different state key
defmodule ModelB do
  import SharedWiring.Orders

  def commands do
    [
      CreateOrder,
      {ViewOrder, view_order_wiring(:pending_orders)},
      {CancelOrder, cancel_order_wiring(:pending_orders, :state)}
    ]
  end
end
```

### Pattern 3: Command Documentation

Since behavior is split between Command and Model, document requirements in the Command:

```elixir
defmodule ViewOrder do
  @moduledoc """
  Views an order by reference.

  ## Generator Requirements

  Requires `order_ref` override - typically provided via Model's `overrides:`:

      {ViewOrder, overrides: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}

  ## Expected Events

  Model's simulate/2 should return one of:
  - `[%OrderViewed{order_ref: ref}]` - if order exists
  - `[%OrderNotFound{order_ref: ref}]` - if order doesn't exist
  """

  defstruct [:order_ref]
  # ...
end
```

## Static Metadata (`command_spec/1`)

A command's static metadata is declared once, on the `command_spec/1` surface,
authored via `use PropertyDamage.Command, <opts>`:

```elixir
use PropertyDamage.Command,
  execution: :probe,                       # :sync (default) | :probe | :async
  shrink: :prefer_remove,                   # read-only commands are pruned first
  observables: [OrderCreated, OrderRejected], # event types this command can produce
  idempotent: false                         # exclude from stutter testing (default true)
```

Each key has a sensible default, so you only declare what differs from the defaults.

## Optional Per-Instance Callbacks

These take the command and/or state, so they stay function callbacks rather than
static spec keys.

### `label/2`

Provide a human-readable label for a command instance:

```elixir
def label(_state, %__MODULE__{order_ref: ref}) do
  "view order #{inspect(ref)}"
end
```

The label is computed lazily when a failure report is built (never during
generation or passing runs), against the command's `command_sequence_projection`
pre-state. It is rendered next to the command in the failure report (terminal,
markdown, JSON) and as a comment in every exported reproduction (ExUnit, scripts,
Livebook), so a minimal repro reads like `# view order ...` next to the offending
step. Return `nil` (or omit the callback) for no label.

### `idempotency_key/1`

Return the idempotency key passed to the adapter during stutter testing.

### `awaits/2`

Declare which inbound (injector) events this command correlates. See
`PropertyDamage.Await`.

## Execution Semantics

Commands declare their execution mode via the `:execution` key of `command_spec/1`.
The execution mode determines how the framework handles the command during testing.

### Sync (default)

Synchronous commands mutate the SUT and complete immediately. The adapter's `execute/3`
is called once and events are recorded.

    use PropertyDamage.Command, execution: :sync

Most commands are sync. Use for operations like create, update, delete.

### Probe

Probes are read-only queries that verify SUT state without mutation. The framework
applies settle/retry logic — re-executing the probe until it succeeds or times out.

    use PropertyDamage.Command, execution: :probe, shrink: :prefer_remove,
      settle: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

Key behaviors:
- Retried automatically according to settle configuration
- Prioritized for removal during shrinking (read-only commands rarely contribute to bugs)
- Do not mutate SUT state — safe to retry
- Use for verifying eventual consistency (e.g., "does the order appear in search results?")

### Async

Async commands create a resource and wait for it to settle. The adapter handles
internal polling, optionally injecting intermediate events via `runtime.inject`.

    use PropertyDamage.Command, execution: :async

Use for operations that return "processing" status and require polling for completion.
Async commands whose refs are used by downstream commands are protected during shrinking.

### Settle Configuration

Probes and async commands use settle configuration for retry behavior:

    settle: %{
      timeout_ms: 5_000,     # Max wait time (default: 2000)
      interval_ms: 200,       # Time between retries (default: 300)
      backoff: :exponential   # :linear (constant interval) or :exponential (doubling)
    }

With `:linear` backoff, retries happen at fixed intervals. With `:exponential`, the
interval doubles after each retry (capped at the timeout).

## Summary

| Concern | Location |
|---------|----------|
| Struct fields | Command |
| Field generation | Command (`generator/1`) |
| Static metadata | Command (`command_spec/1` / `use` options) |
| When to enable | Model (`when:` option) |
| State-dependent params | Model (`overrides:` option) |
| Expected events | Simulator (`simulate/2` via `simulator/0`) |
| State shape | Model's projection |
