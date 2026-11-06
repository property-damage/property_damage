# DR-062: Fault Injection Is Removed

**Status:** Accepted
**Date:** 2026-11-06

## Context

PropertyDamage let a model list a `Nemesis` module in `commands/0` next to
ordinary commands. A nemesis injected a fault (`inject/2`), restored it
(`restore/2`) and carried its own lifecycle: a precondition, an auto-restore
timer and an executor stage that tracked the faults still active. Three
built-in modules (`NetworkLatency`, `NetworkPartition`, `PacketLoss`) drove a
Toxiproxy control API through a small HTTP client.

The model decides what runs and when, and a command is a pure generator. A
nemesis broke that split. The generator had to dispatch a second kind of
command with its own callbacks (`new!/2`, `precondition/1`; DR-031), the
executor ran it through a separate path, and the failure and event-log
vocabulary grew a failure kind and an event source for it.

## Decision

1. The `PropertyDamage.Nemesis` behaviour, the three built-in modules, the
   Toxiproxy client and `PropertyDamage.Executor.Nemesis` are removed.
2. The generator dispatches only commands. `Validation` and `Model` no longer
   check for fault-injection commands, and `Executor.State` no longer carries
   `active_faults`.
3. The `:nemesis_error` failure kind and `Failure.nemesis_error/1` are removed.
   The `:nemesis` event source, the `nemesis_module` field of
   `PropertyDamage.EventLog.Entry`, `Entry.from_nemesis/4` and
   `Entry.nemesis?/1` are removed. An entry names one of seven sources,
   listed by `Entry.sources/0`.
4. The persistence format becomes version `17`. A file of version `1` to `16`
   is refused with `{:unsupported_format_version, version, 17}`. The loader
   also checks the `source` of every event-log entry of a loaded report, its
   reference trace and a standalone trace, and refuses a source outside
   `Entry.sources/0` with `{:error, {:unknown_event_source, source}}`.
5. The chaos engineering guide, the fault-injection spec and the nemesis
   passages of the other guides and specs are removed. The Redis bench drops
   its Toxiproxy service, proxy adapter and fault-injection suites, and runs
   against plain Redis.

No replacement ships in this version. Fault injection will be approached again
outside the command engine.

## Alternatives

- **Keep it and redesign how faults reach the generator.** Rejected: the
  redesign is the open question. Keeping the current shape until then keeps
  the second command lifecycle in the engine.
- **Keep a neutral `:fault` event source and failure kind as placeholders.**
  Rejected: they would be dead values until a design exists, and the loader
  would accept events no code produces.
- **Keep the fault-injection spec as a requirements document that does not
  name an injector.** Rejected: the docs gate checks the docs against the
  code, and the spec would describe nothing the code does.

## Consequences

- Users lose the `Nemesis` behaviour, the three built-in modules and the
  Toxiproxy client. A model that lists a nemesis in `commands/0` fails
  validation, because the module no longer exists.
- Saved `.pd` and `.pdtrace` files of version 16 and earlier no longer load.
  The user captures the failure again.
- The replay artifact keeps format `2`: it records commands, and a command is
  unchanged.
- The Redis bench runs against plain Redis and needs no Toxiproxy container.
- DR-031 and DR-038 are superseded. DR-029 keeps its record of the executor
  stages, with a note that the fault-injection stage was removed.
