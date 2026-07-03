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

- See `example_tests/travel_booking/` for a complete chaos engineering example
- Read about [Writing Invariants](writing_invariants.md) for fault-aware checks
- Use `PropertyDamage.Mutation` to verify your chaos tests catch bugs
