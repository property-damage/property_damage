# Chaos Engineering with Nemesis

PropertyDamage includes nemesis operations for fault injection testing.
This enables chaos engineering - verifying your system handles failures
gracefully.

## What is Chaos Engineering?

Chaos engineering answers: **"What happens when things go wrong?"**

Instead of hoping your system handles failures, you deliberately inject
faults and verify the system responds correctly.

## Scope: nemeses fault the SUT, not the test harness

The built-in nemeses fault the System Under Test's **network path**. They
deliberately do not stress the local BEAM/host (CPU, memory, OS resources),
kill local processes, or install a virtual clock the adapter reads. Those would
only affect the test harness's own VM, not an external SUT driven through an
adapter, so they test the wrong thing (and host-stress faults can destabilize
the run itself). If you need to fault an in-process collaborator, do it in your
own adapter or command code, where you control the boundary.

## Built-in Nemesis Operations

| Operation | What It Tests |
|-----------|---------------|
| `NetworkLatency` | Timeout handling, retries |
| `NetworkPartition` | Split-brain, failover |
| `PacketLoss` | Reliability, retry logic |

## Real vs simulated faults (important)

PropertyDamage is explicit about whether a nemesis actually injected a fault, so
a fault that did nothing can never look like one that did.

**Network faults need Toxiproxy.** `NetworkLatency`, `NetworkPartition` and
`PacketLoss` can only degrade the network when Toxiproxy is configured in the
adapter context:

```elixir
# adapter setup/1 returns a context carrying the Toxiproxy endpoint
{:ok, %{toxiproxy: %{proxy_name: "redis", api_url: "http://localhost:8474"}}}
```

Without it, these nemeses do **nothing** and tag their event with
`simulated: true`. Check it with `PropertyDamage.Nemesis.simulated_event?/1`,
or match on the `:simulated` field, so your invariants are not fooled by a
no-op "fault".

Auto-restoring faults (`auto_restore?/0` returning true, the default) are lifted
automatically: PropertyDamage calls `restore/2` once a fault's `duration_ms` has
elapsed during the run, and restores any still-active faults when the sequence
ends, so a fault never leaks past the test that injected it.

## Run it now: a complete chaos test

Here is a full, self-contained chaos run you can paste into `cache_chaos.exs` and
execute with `mix run cache_chaos.exs`. The SUT is a tiny in-process key/value
cache (an `Agent`), the model mixes ordinary `SetKey`/`GetKey` operations with the
`NetworkLatency` nemesis, and a projection both tracks active faults and asserts
read consistency. Because `setup/1` returns **no** `:toxiproxy` key, this runs in
**simulated mode** (see the section below for the live variant).

```elixir
defmodule Cache.Events do
  defmodule KeySet do
    defstruct [:key, :value]
  end

  defmodule KeyRead do
    defstruct [:key, :value]
  end
end

defmodule Cache.Commands.SetKey do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key, :value]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.member_of(["a", "b", "c"]),
      value: StreamData.integer(0..100)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Cache.Commands.GetKey do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    # key is filled in by the model from state (a key that was written).
    %{key: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Cache.Adapter do
  use PropertyDamage.Adapter

  alias Cache.Commands.{SetKey, GetKey}
  alias Cache.Events.{KeySet, KeyRead}

  @impl true
  def setup(_config) do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    # No :toxiproxy key here -> network nemeses run in simulated mode.
    {:ok, %{store: store}}
  end

  @impl true
  def teardown(%{store: store}), do: Agent.stop(store)

  @impl true
  def execute(%SetKey{key: key, value: value}, %{store: store}, _runtime) do
    Agent.update(store, &Map.put(&1, key, value))
    {:ok, [%KeySet{key: key, value: value}]}
  end

  def execute(%GetKey{key: key}, %{store: store}, _runtime) do
    value = Agent.get(store, &Map.get(&1, key))
    {:ok, [%KeyRead{key: key, value: value}]}
  end
end

defmodule Cache.State do
  use PropertyDamage.Model.Projection

  alias Cache.Events.{KeySet, KeyRead}

  @impl true
  def init do
    %{store: %{}, active_faults: %{}, simulated_faults: 0, real_faults: 0}
  end

  @impl true
  def apply(state, %KeySet{key: key, value: value}) do
    put_in(state, [:store, key], value)
  end

  # Nemesis emits its own injected/restored structs; match the ones you use.
  def apply(state, %NetworkLatencyInjected{} = event) do
    state
    |> put_in([:active_faults, :network_latency], event)
    |> bump_fault_counter(event)
  end

  def apply(state, %NetworkLatencyRestored{}) do
    update_in(state, [:active_faults], &Map.delete(&1, :network_latency))
  end

  def apply(state, _), do: state

  defp bump_fault_counter(state, event) do
    if PropertyDamage.Nemesis.simulated_event?(event) do
      update_in(state, [:simulated_faults], &(&1 + 1))
    else
      update_in(state, [:real_faults], &(&1 + 1))
    end
  end

  # Consistency holds whether or not a fault is active: a read returns the last
  # written value. (An in-memory cache is always fast, so there is no SLA to
  # relax here; see "Relaxing Invariants During Faults" below for that pattern.)
  @trigger every: Cache.Events.KeyRead
  def assert_reads_are_consistent(state, %KeyRead{key: key, value: value}) do
    expected = Map.get(state.store, key)

    unless value == expected do
      PropertyDamage.fail!("stale read", key: key, got: value, expected: expected)
    end
  end
end

defmodule Cache.ChaosModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias Cache.Commands.{SetKey, GetKey}
  alias Cache.Events.{KeySet, KeyRead}
  alias PropertyDamage.Nemesis.NetworkLatency
  alias Cache.State

  @impl true
  def commands do
    [
      {SetKey, weight: 4},
      {GetKey,
       weight: 4,
       when: fn state -> map_size(state.store) > 0 end,
       with: fn state -> %{key: StreamData.member_of(Map.keys(state.store))} end},
      # Low weight = occasional faults.
      {NetworkLatency, weight: 1}
    ]
  end

  @impl true
  def command_sequence_projection, do: State

  @impl true
  def assertion_projections, do: [State]

  # The simulator predicts events during sequence generation so state-dependent
  # commands (GetKey needs a key to exist) become eligible. The catch-all covers
  # nemesis commands, which emit no domain events during generation.
  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%SetKey{key: key, value: value}, _state), do: [%KeySet{key: key, value: value}]
  def simulate(%GetKey{key: key}, _state), do: [%KeyRead{key: key, value: nil}]
  def simulate(_command, _state), do: []
end

result =
  PropertyDamage.run(
    model: Cache.ChaosModel,
    adapter: Cache.Adapter,
    max_commands: 12,
    max_runs: 20,
    seed: 7
  )

IO.inspect(result, label: "run result")
```

It prints a passing result (your `assertion_fires` count varies with the seed):

```
run result: {:ok,
 %{
   seed: 7,
   assertion_fires: %{{Cache.State, :reads_are_consistent} => 212},
   runs: 20,
   total_commands: 240
 }}
```

The run is green, but note what it did *not* prove: because no Toxiproxy was
configured, every injected `NetworkLatency` was a no-op. The `Cache.State`
projection counted those in its `simulated_faults` field via
`simulated_event?/1` — a real fault run would land them in `real_faults` instead.
The next section makes that distinction concrete.

## Simulated vs real faults, side by side

You can see the exact marker flip without a full run by calling a nemesis's
`inject/2` directly. With no Toxiproxy in the context, the fault is simulated:

```elixir
alias PropertyDamage.Nemesis.NetworkLatency

# No Toxiproxy configured -> nothing is sent anywhere.
{:ok, [event]} = NetworkLatency.inject(%NetworkLatency{latency_ms: 100}, %{})
event.simulated
#=> true
PropertyDamage.Nemesis.simulated_event?(event)
#=> true
```

To make the fault real, point the nemesis at a running Toxiproxy. The repo ships a
ready-made recipe at `benches/redis_bench/docker-compose.yml` (Redis behind a
Toxiproxy on control port `8474`); bring it up with:

```bash
cd benches/redis_bench && docker compose up -d
```

Then create a proxy and inject with the Toxiproxy endpoint in the context. The
same event now reports `simulated: false`, and the latency toxic really lands on
the proxy:

```elixir
Application.ensure_all_started(:inets)
api = "http://localhost:8474"

# Create a proxy named "redis" forwarding to the container's Redis.
body = Jason.encode!(%{
  "name" => "redis",
  "listen" => "0.0.0.0:6391",
  "upstream" => "redis:6379",
  "enabled" => true
})

:httpc.request(:post, {~c"#{api}/proxies", [], ~c"application/json", body}, [], [])

# Inject WITH a discovered Toxiproxy config.
ctx = %{toxiproxy: %{proxy_name: "redis", api_url: api}}
{:ok, [event]} = NetworkLatency.inject(%NetworkLatency{latency_ms: 100, jitter_ms: 20}, ctx)
event.simulated
#=> false
```

In a full `PropertyDamage.run`, you reach the real path the same way: have your
adapter's `setup/1` return `%{toxiproxy: %{proxy_name: ..., api_url: ...}}` (the
proxy your SUT actually connects through), and route the SUT's traffic through that
proxy. Every injected-latency event then carries `simulated: false` and the
degradation is real. The `simulated: true` output above comes from the
no-Toxiproxy run; the `simulated: false` output comes from a live Toxiproxy started
via the compose file — do not mix them up when reading a report.

## Quick Start

### 1. Create a Chaos Model

Extend your model with nemesis commands:

```elixir
defmodule MyApp.ChaosModel do
  @behaviour PropertyDamage.Model

  # Regular commands
  alias MyApp.Commands.{CreateOrder, ProcessOrder, CancelOrder}

  # Nemesis commands
  alias PropertyDamage.Nemesis.{NetworkLatency, NetworkPartition, PacketLoss}

  @impl true
  def commands do
    [
      # Regular operations (higher weights)
      {CreateOrder, weight: 5},
      {ProcessOrder, weight: 3},
      {CancelOrder, weight: 2},

      # Nemesis operations (lower weights = occasional faults)
      {NetworkLatency, weight: 1},
      {NetworkPartition, weight: 1},
      {PacketLoss, weight: 1}
    ]
  end

  # ... rest of model
end
```

### 2. Add Nemesis-Aware Invariants

Create a projection that tracks active faults:

```elixir
defmodule MyApp.Projections.NemesisInvariants do
  use PropertyDamage.Model.Projection

  @impl true
  def init do
    %{
      active_faults: %{},
      operations_during_fault: []
    }
  end

  # Track fault injection. There is no generic fault event: each nemesis emits
  # its own injected/restored structs (NetworkLatencyInjected,
  # NetworkLatencyRestored, PacketLossInjected, ...). Match the ones your model
  # uses; the injected struct carries a `simulated: true | false` flag.
  @impl true
  def apply(state, %NetworkLatencyInjected{} = event) do
    put_in(state, [:active_faults, :network_latency], event)
  end

  def apply(state, %NetworkLatencyRestored{}) do
    update_in(state, [:active_faults], &Map.delete(&1, :network_latency))
  end

  def apply(state, _), do: state

  # Use the tracked faults to RELAX other invariants while a fault is active
  # (see "Relaxing Invariants During Faults" below). The executor
  # auto-restores faults whose duration has elapsed and restores any still
  # active at the end of the sequence, so there is no end-of-sequence
  # "orphaned fault" check to write.
end
```

### 3. Adapter changes: none

The network nemeses act at the Toxiproxy layer: route your SUT through the proxy
and they degrade the connection transparently, with no adapter changes. Your
`execute/3` makes ordinary SUT calls; when a fault is active the call naturally
slows or fails. When no Toxiproxy is configured, the injected event is tagged
`simulated: true` so your invariants can tell a real fault from a no-op.

## Network Operations

### NetworkLatency

Simulate slow network responses:

```elixir
alias PropertyDamage.Nemesis.NetworkLatency

# Add 100ms latency with 20ms jitter
%NetworkLatency{
  latency_ms: 100,
  jitter_ms: 20,
  duration_ms: 10_000
}

# Applied at the Toxiproxy layer in inject/2 -- no adapter cooperation needed.
# Without a configured Toxiproxy the injected event is tagged simulated: true.
```

### NetworkPartition

Simulate network splits:

```elixir
alias PropertyDamage.Nemesis.NetworkPartition

# Full partition - no traffic either direction
%NetworkPartition{
  partition_type: :full,
  duration_ms: 5000
}

# Directional - block one direction only
%NetworkPartition{
  partition_type: :downstream,
  duration_ms: 5000
}
```

### PacketLoss

Simulate unreliable network:

```elixir
alias PropertyDamage.Nemesis.PacketLoss

# 10% packet loss
%PacketLoss{
  loss_percent: 10,
  duration_ms: 10_000
}
```

## Relaxing Invariants During Faults

Some invariants don't apply during faults. Adjust checks accordingly:

```elixir
@trigger every: 1
def assert_response_time_sla(state, _cmd_or_event) do
  # Don't check SLA during network partition
  if has_active_fault?(state, :network_partition) do
    :ok
  else
    if state.last_response_ms < 100 do
      :ok
    else
      {:error, "SLA violated: #{state.last_response_ms}ms"}
    end
  end
end

defp has_active_fault?(state, type) do
  Map.has_key?(state.active_faults, type)
end
```

## Toxiproxy Integration

For network operations, PropertyDamage can integrate with
[Toxiproxy](https://github.com/Shopify/toxiproxy):

```elixir
# Return the Toxiproxy endpoint from your adapter's setup/1 so it lands in the
# adapter context the engine hands to the nemeses (DR-038).
def setup(_config) do
  {:ok,
   %{
     toxiproxy: %{
       proxy_name: "my_service",
       api_url: "http://localhost:8474"
     }
   }}
end

# Nemesis operations will use Toxiproxy automatically.
# Falls back to simulated mode (events tagged simulated: true) if not configured.
```

## Example: Complete Chaos Model

```elixir
defmodule TravelBooking.ChaosModel do
  @behaviour PropertyDamage.Model

  # Regular commands
  alias TravelBooking.Commands.{CreateBooking, AddFlight, AddHotel, ConfirmBooking}

  # Nemesis commands (network faults via Toxiproxy)
  alias PropertyDamage.Nemesis.{NetworkLatency, NetworkPartition, PacketLoss}

  alias TravelBooking.Projections.{ModelState, BookingInvariants, NemesisInvariants}

  @impl true
  def commands do
    [
      # Regular operations (70-80% of commands)
      {CreateBooking, weight: 5},
      {AddFlight, weight: 4},
      {AddHotel, weight: 4},
      {ConfirmBooking, weight: 2},

      # Nemesis operations (20-30% of commands)
      {NetworkLatency, weight: 1},
      {NetworkPartition, weight: 1},
      {PacketLoss, weight: 1}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  @impl true
  def assertion_projections do
    [
      BookingInvariants,
      NemesisInvariants
    ]
  end
end
```

## Best Practices

1. **Start with low fault rates** - Weight nemesis commands at 1 while
   regular commands are 3-5

2. **Test one fault type at a time** - Easier to debug failures

3. **Don't be fooled by simulated faults** - Assert against the `:simulated`
   flag (or `simulated_event?/1`) so an un-backed network nemesis can't pass as
   a real one

4. **Relax appropriate invariants** - SLA checks don't apply during partitions

5. **Use auto-restore** - Nemesis operations automatically restore after
   their duration

6. **Log fault injection** - Track when faults are active for debugging

## What Chaos Engineering Detects

- Missing error handling
- Incorrect retry behavior
- Missing circuit breakers
- Resource leaks during failures
- Inconsistent state after partial failures
- Missing timeout handling
- Poor error messages to users

## MockServiceAdapter vs Nemesis

PropertyDamage provides two complementary approaches to fault testing:

**Nemesis** operates at the network level — partitions, latency spikes, packet
loss. Nemesis faults affect how the SUT communicates, not what responses it
receives.

**MockServiceAdapter** operates at the application level — controlling what third-party
APIs return. Mock a payment provider declining transactions, an email service timing out,
or a shipping API returning partial failures.

| Concern | Use Nemesis | Use MockServiceAdapter |
|---------|-------------|----------------------|
| Network unreachable | ✓ | |
| API returns 500 | | ✓ |
| High latency | ✓ | |
| API declines request | | ✓ |
| Packet loss | ✓ | |
| API returns unexpected format | | ✓ |

**Rule of thumb:** If the fault is about the pipe (network), use Nemesis.
If the fault is about what comes through the pipe (API responses, business logic), use
MockServiceAdapter.

See [Mocking Third Parties](mocking_third_parties.md) for complete MockServiceAdapter
usage.

## Next Steps

- See `benches/redis_bench/` for a complete, CI-gated chaos/fault-injection example (live Toxiproxy)
- Read about [Writing Invariants](writing_invariants.md) for fault-aware checks
- Use `PropertyDamage.Mutation` to verify your chaos tests catch bugs
