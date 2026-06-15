# Chaos Engineering with Nemesis

PropertyDamage includes nemesis operations for fault injection testing.
This enables chaos engineering - verifying your system handles failures
gracefully.

## What is Chaos Engineering?

Chaos engineering answers: **"What happens when things go wrong?"**

Instead of hoping your system handles failures, you deliberately inject
faults and verify the system responds correctly.

## Built-in Nemesis Operations

PropertyDamage provides these fault injection operations:

| Category | Operation | What It Tests |
|----------|-----------|---------------|
| **Network** | `NetworkLatency` | Timeout handling, retries |
| | `NetworkPartition` | Split-brain, failover |
| | `PacketLoss` | Reliability, retry logic |
| **Resource** | `MemoryPressure` | OOM handling, GC behavior |
| | `CPUStress` | Scheduler starvation |
| | `ResourceExhaustion` | File descriptor limits |
| **Time** | `ClockSkew` | Time-based logic, TTLs |
| **Process** | `ProcessKill` | Supervisor recovery |
| | `SlowIO` | I/O bound operations |
| **Security** | `CertificateExpiry` | TLS error handling |

## Real vs simulated faults (important)

Not every nemesis injects a real fault in every environment, and PropertyDamage
is explicit about which is which so a fault that did nothing can never look like
one that did:

- **Network faults need Toxiproxy.** `NetworkLatency`, `NetworkPartition` and
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

- **Host-effect faults are always real.** `CPUStress`, `MemoryPressure`,
  `ResourceExhaustion` and `ProcessKill` act directly on the BEAM/host with no
  extra setup.

- **Cooperative faults are real but need your adapter to look.** `ClockSkew`,
  `SlowIO` and `CertificateExpiry` install real state, but only change behavior
  if your adapter consults their public API (e.g. `ClockSkew.now/0`,
  `SlowIO.apply_delay/0`, `CertificateExpiry.should_fail?/1`).

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
  alias PropertyDamage.Nemesis.{
    NetworkLatency,
    NetworkPartition,
    CertificateExpiry
  }

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
      {CertificateExpiry, weight: 1}
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

### 3. Update Your Adapter

The network nemeses (NetworkLatency, NetworkPartition, PacketLoss) act at the
Toxiproxy layer and need no adapter changes: route your SUT through the proxy
and they degrade the connection transparently (and tag their events
`simulated: true` when no Toxiproxy is configured). The cooperative nemeses
(SlowIO, CertificateExpiry, ClockSkew) instead expose a helper your adapter
calls:

```elixir
defmodule MyApp.ChaosAdapter do
  @behaviour PropertyDamage.Adapter

  alias PropertyDamage.Nemesis.{SlowIO, CertificateExpiry}

  @impl true
  def execute(cmd, ctx) do
    # Cooperative nemeses expose a helper your adapter consults. SlowIO and
    # CertificateExpiry are the ones with an adapter-facing API:
    if SlowIO.should_delay?() do
      SlowIO.apply_delay()
    end

    if CertificateExpiry.should_fail?() do
      # Returns an SSL error tuple to feed back as a failed observation
      CertificateExpiry.get_ssl_error()
    else
      do_execute(cmd, ctx)
    end
  end

  # ... actual execution
end
```

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

# Asymmetric - one direction degraded
%NetworkPartition{
  partition_type: :asymmetric,
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

## Resource Operations

### MemoryPressure

Simulate memory pressure:

```elixir
alias PropertyDamage.Nemesis.MemoryPressure

# Allocate 100MB
%MemoryPressure{
  megabytes: 100,
  allocation_pattern: :bulk,  # or :fragmented
  duration_ms: 5000
}
```

### CPUStress

Stress the scheduler:

```elixir
alias PropertyDamage.Nemesis.CPUStress

# High load across all schedulers (intensity is a 1-10 level, default 5)
%CPUStress{
  intensity: 8,
  schedulers: :all,  # or specific count
  duration_ms: 5000
}
```

## Time Operations

### ClockSkew

Simulate clock drift:

```elixir
alias PropertyDamage.Nemesis.ClockSkew

# Jump forward 1 hour (positive skew = future), no ongoing drift
%ClockSkew{
  skew_ms: 3_600_000,
  drift_rate: 1.0  # 1.0 = normal rate (no drift); >1.0 fast, <1.0 slow
}

# Jump back 1 hour, then run 2x fast
%ClockSkew{
  skew_ms: -3_600_000,
  drift_rate: 2.0,
  duration_ms: 5000
}

# In your code, use the virtual clock:
ClockSkew.now()  # Returns adjusted time
```

## Security Operations

### CertificateExpiry

Simulate TLS certificate failures:

```elixir
alias PropertyDamage.Nemesis.CertificateExpiry

# Expired certificate
%CertificateExpiry{
  failure_type: :expired,
  target: :api,  # or :all, :specific_service
  duration_ms: 10_000
}

# Hostname mismatch
%CertificateExpiry{
  failure_type: :wrong_host,
  target: :payment_gateway
}

# In adapter:
if CertificateExpiry.should_fail?(:api) do
  CertificateExpiry.get_ssl_error()
  # Returns {:error, {:tls_alert, {:certificate_expired, ~c"certificate has expired"}}}
end
```

Available failure types:
- `:expired` - Certificate past validity
- `:not_yet_valid` - Certificate not yet valid
- `:wrong_host` - Hostname mismatch
- `:self_signed` - Untrusted CA
- `:revoked` - Certificate revoked

## Process Operations

### ProcessKill

Kill processes to test recovery:

```elixir
alias PropertyDamage.Nemesis.ProcessKill

# Kill by name
%ProcessKill{
  target: {:name, :my_worker},
  signal: :kill
}

# Kill random supervised child
%ProcessKill{
  target: {:supervised_by, MyApp.WorkerSupervisor},
  signal: :shutdown
}

# Kill by pattern
%ProcessKill{
  target: {:pattern, ~r/worker/},
  signal: :kill
}
```

### SlowIO

Simulate slow disk I/O:

```elixir
alias PropertyDamage.Nemesis.SlowIO

%SlowIO{
  delay_ms: 50,
  target: :all,  # :reads, :writes, or :all
  duration_ms: 10_000
}

# In your I/O code:
if SlowIO.should_delay?(:reads) do
  SlowIO.apply_delay()
end
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

@trigger every: 1
def assert_all_requests_succeed(state, _cmd_or_event) do
  # Allow failures during certificate issues
  if has_active_fault?(state, :certificate_expiry) do
    :ok
  else
    # Normal check
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
# Configure in adapter
adapter_config: %{
  toxiproxy: %{
    proxy_name: "my_service",
    api_url: "http://localhost:8474"
  }
}

# Nemesis operations will use Toxiproxy automatically
# Falls back to simulated mode if not configured
```

## Example: Complete Chaos Model

```elixir
defmodule TravelBooking.ChaosModel do
  @behaviour PropertyDamage.Model

  # Regular commands
  alias TravelBooking.Commands.{
    CreateBooking,
    AddFlight,
    AddHotel,
    ConfirmBooking
  }

  # Nemesis commands
  alias TravelBooking.Nemesis.{
    InjectLatency,
    InjectProviderError,
    InjectCertificateFailure,
    InjectPartialFailure
  }

  alias TravelBooking.Projections.{
    ModelState,
    BookingInvariants,
    NemesisInvariants
  }

  @impl true
  def commands do
    [
      # Regular operations (70-80% of commands)
      {CreateBooking, weight: 5},
      {AddFlight, weight: 4},
      {AddHotel, weight: 4},
      {ConfirmBooking, weight: 2},

      # Nemesis operations (20-30% of commands)
      {InjectLatency, weight: 1},
      {InjectProviderError, weight: 1},
      {InjectCertificateFailure, weight: 1},
      {InjectPartialFailure, weight: 1}
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

3. **Verify fault cleanup** - Use `:no_orphaned_faults` invariant

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
- Missing security event logging

## MockServiceAdapter vs Nemesis

PropertyDamage provides two complementary approaches to fault testing:

**Nemesis** operates at the infrastructure level — network partitions, latency spikes,
CPU pressure, clock skew. Nemesis faults affect how the SUT communicates, not what
responses it receives.

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
| Clock drift | ✓ | |
| Third-party behavior changes | | ✓ |

**Rule of thumb:** If the fault is about the pipe (network, infrastructure), use Nemesis.
If the fault is about what comes through the pipe (API responses, business logic), use
MockServiceAdapter.

See [Mocking Third Parties](mocking_third_parties.md) for complete MockServiceAdapter
usage.

## Next Steps

- See `example_tests/travel_booking/` for a complete chaos engineering example
- Read about [Writing Invariants](writing_invariants.md) for fault-aware checks
- Use `PropertyDamage.Mutation` to verify your chaos tests catch bugs
