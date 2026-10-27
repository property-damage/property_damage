# DR-054: Log Lines for the Failure Report

**Status:** Proposed
**Date:** 2026-10-27

## Context

A failure report shows what the model saw: commands, events and projection
state. It does not show what the adapter did to produce them: the requests it
sent, the responses it read, the rows it seeded before the run. In a
black-box test, that is where the explanation of a failure usually lives. An
adapter author who wants it today prints to the console, and those prints
come from every run, passing or failing, and are not tied to the step that
made them.

Three constraints shape any answer.

- `Adapter.execute/3` runs inside a `Task` (`PropertyDamage.Executor.Timeout`),
  and a command timeout kills that task. Anything the adapter keeps in its own
  process dies with it, so the lines that explain a hang would be lost exactly
  when they matter most.
- DR-027 removed ambient process-dictionary state from the adapter path,
  because that state does not cross into processes the adapter starts.
- Work that prepares a system for a run often happens before the run starts,
  for example in an ExUnit `setup_all`. Setup commands (DR-048) run again for
  every run and every shrink attempt, so expensive seeding does not belong
  there, and its lines still matter when a failure depends on it.

## Decision

1. **One destination: the failure report.** A log line exists only to be shown
   in a failure report. PropertyDamage never forwards a line to Elixir's
   `Logger`, never prints one during a run, and has no levels: levels exist to
   route lines between destinations, and there is only one.

2. **One macro.** `PropertyDamage.log(message, opts \\ [])`, behind
   `require PropertyDamage`. The macro records the file and line of the call,
   and the report can print them. `opts` takes one key, `tags:`, a list of
   atoms; any other value is a compile error.

3. **Three message forms.**

   | Form | When it is formatted | How it is shown |
   |------|----------------------|-----------------|
   | a string | at the call | as written |
   | any other value | when a report is built | `inspect(value, pretty: true)`, with `syntax_colors:` when the report is colored |
   | a 0-arity function | when a report is built | its result, by the two rules above |

   A value is stored as it was at the call, and Elixir values cannot change,
   so the report shows it as it was. A function runs after the run has ended:
   if it reads state that can change (an `Agent`, an ETS table, another
   process), it sees the end-of-run value or fails because the process is
   gone. The report builder calls each function inside `try` and prints
   `(log line raised: ...)` for one that raises. The macro never wraps a
   message in a function on its own, because that would give every call the
   late-read trap without showing it.

4. **Every call needs a scope.** A scope is either an execution point of a run
   (decision 5) or a `PropertyDamage.Log.capture/1` call (decision 8).
   `PropertyDamage.log/2` looks for a scope in the calling process, then in
   each process of its `$callers` list, so a `Task` that the adapter starts
   logs to the step that started it. A call that finds no scope raises an
   error that names the call site, the calling process and the fixes: call it
   from a scope, wrap the code in `Log.capture/1`, or use `Runtime.log/3`.
   Inside `execute/3`, that raise becomes an adapter error, and the report
   classifies it as a test code error, not as a bug in the system under test.
   The raise depends on the code's structure, not on timing, so it fires on
   the first run.

5. **Every phase that runs user code is an execution point.** The executor
   sets a point before it calls into user code: `Adapter.setup/1`, each setup
   command, each root and each leaf (DR-049), each attempt of a settle or
   stutter retry, nemesis `inject/2` and `restore/2`, mock handlers, teardown
   commands and `Adapter.teardown/1`. A point names the target, the position
   and the attempt.

6. **The explicit form.** `%PropertyDamage.Runtime{}` gains a `log` function
   beside `inject` and `start_poller`, and `PropertyDamage.Runtime.log/3`
   (`runtime, message, opts`) calls it. A process the adapter does not start
   through `Task`, such as a `GenServer`, logs through the runtime it was
   handed. `PropertyDamage.log/2` is a lookup of that same function, so both
   forms write to the same place.

7. **Storage outlives the task.** Each line goes, at the call and
   synchronously, into the command's `PropertyDamage.Runtime.Sink` (DR-027),
   which the executor owns. A timeout kill or a raise in `execute/3` loses no
   line written before it. When the command ends, the executor moves the
   lines into the run's `RunTrace` under a `logs` field keyed by position, and
   `RunTrace.Step` gains a `logs` field. Lines never enter the event log,
   because projections, exporters and run comparison read the event log and
   expect events in it.

8. **`Log.capture/1` covers code outside a run.**
   `PropertyDamage.Log.capture(fun)` runs `fun` as a scope and returns
   `{result, lines}`. The same `$callers` rule applies, and a nested
   `capture/1` collects into the innermost one. A test passes the lines to the
   run as `setup_log: lines`, and the report prints them once, in a Setup
   section before the reproduction, labeled as shared by every run. Nothing
   hidden carries lines from one process to another: the test hands them over
   as a value.

9. **Lines live only in memory.** A run's lines are dropped when the run ends,
   unless the run is the one reported; a failing shrink attempt that is not
   the final report drops them too. Lines are never written to a replay
   artifact (DR-050), a saved trace or any other file. Those files get
   committed, and a line the caller forgot to redact would be published. The
   report's own output (terminal, markdown, JSON) carries them. Saving a trace
   drops its `logs` field, and loading one sets `logs` to an empty map, so the
   saved format does not change, the persistence version stays, and traces
   saved before this record still load. A report built from a saved trace or
   a replay artifact therefore shows no log lines until a replay runs the
   failure again.

10. **The caller redacts.** PropertyDamage cannot find a secret inside a
    string it did not build, so the code that calls `PropertyDamage.log/2`
    removes secrets before the call. Tag filters (decision 11) hide lines from
    one reader; they do not protect secrets, because the next reader turns
    them off.

11. **Tags are the only display filter.** A run, a replay call and
    `PropertyDamage.ExUnit.format_failure/2` take `log: [only: tags, except:
    tags]`.
    - `only:` shows the tagged lines that carry any listed tag.
    - Untagged lines are always shown.
    - `except:` hides lines that carry any listed tag, and wins over `only:`.
    - A tag listed in either option that no line carries prints a warning in
      the report, so a typo does not read as "nothing happened".

    The report has no logic that hides parts of a line and no truncation. An
    author who wants the parts of a call shown separately (address, headers,
    body, a short preview of the body) logs each part in its own call under
    its own tag, and the reader combines tags to choose what to see.

12. **Rendering.** Under each step, the report prints the step's log lines and
    events in timestamp order. Each line shows its offset from the target's run
    start and its tags (`+3.10s [http url]`); a multi-line value is indented
    under its line. Values in commands, events and the Failure section use the
    same colored `inspect`, except in the projection diff, which keeps its
    red and green diff colors.

## Example

A shared HTTP helper logs each part of a request under its own tag:

```elixir
require PropertyDamage

def request(method, url, headers, body) do
  PropertyDamage.log("#{method} #{url}", tags: [:http, :url])
  PropertyDamage.log(redact(headers), tags: [:http, :headers])
  PropertyDamage.log(body, tags: [:http, :body])

  {status, response} = send_request(method, url, headers, body)
  PropertyDamage.log("-> #{status}", tags: [:http, :status])
  PropertyDamage.log(fn -> Jason.decode!(response) end, tags: [:http, :response])
  {status, response}
end
```

A test that seeds its system once logs the seeding through `capture/1`:

```elixir
setup_all do
  {accounts, setup_log} =
    PropertyDamage.Log.capture(fn ->
      PropertyDamage.log("seeding accounts", tags: [:seed])
      MySystem.seed!(alice: 100, bob: 0)
    end)

  %{accounts: accounts, setup_log: setup_log}
end

test "transfers agree", %{accounts: accounts, setup_log: setup_log} do
  PropertyDamage.run(model: MyModel, targets: targets(accounts),
    setup_log: setup_log, log: [except: [:headers]])
end
```

## Consequences

- An adapter author gets step-attributed diagnostics in the report with one
  `require` and no configuration, and pays a scope lookup plus one write per
  line on a passing run. Values and functions are never formatted on a passing
  run, so fast in-memory adapters that log large terms stay fast.
- A helper that calls `PropertyDamage.log/2` can only run inside a scope. A
  helper also used outside PropertyDamage needs its callers there to wrap it in
  `Log.capture/1`.
- A process that is neither the executing task nor one started through `Task`
  cannot use `PropertyDamage.log/2`; the docs point it to `Runtime.log/3`.
- This record amends DR-027. The process dictionary returns, but only to locate
  the sink that a call writes to; every line is still written to the explicit
  sink, and `Runtime.log/3` keeps the explicit path for every process.
- Each target's lines are attributed to that target's points. The report shows
  the reference target's lines only if it keeps the reference's trace, which is
  a separate decision about the failure report.
- Changing what the report shows means building the report again. A test that
  holds the report can format it again; otherwise the replay call reruns the
  failure, and a replay that does not reproduce it shows no lines for it.

## Alternatives considered

- **Capture Elixir's `Logger`.** A `:logger` handler can find the step the same
  way, and adapters would need no new API. Rejected: a common test setting
  such as `config :logger, level: :warning` drops `debug` and `info` calls
  before any handler sees them, with no warning. Libraries' debug logs would
  be captured too, including headers no one redacted. And the console would
  print the lines of every run unless the user reconfigures handler levels.
- **A module named `PropertyDamage.Logger` with `Logger`'s API.** Rejected: an
  `alias PropertyDamage.Logger` silently redirects every `Logger` call in that
  module, and copying `Logger`'s API makes its signature a promise to keep.
- **Forward to `Logger` outside a run.** Rejected: it ties the API to
  `Logger`'s signature, and it sends a line somewhere other than where its
  author meant without saying so. A user who wants the console calls `Logger`.
- **Do nothing outside a scope.** Rejected: a line dropped without a word looks
  the same in the report as code that never ran.
- **Levels.** Rejected: with one destination, nothing reads them. Tags do the
  filtering.
- **Hiding fields of a line, or truncating values.** Rejected: both add display
  logic for one part of a line. Separate tagged calls give the reader the same
  control with no logic in the report.
- **A `log:` function option on each helper.** Considered while the rule was
  "no scope outside a run". `Log.capture/1` gives code outside a run a scope,
  so helpers can call `PropertyDamage.log/2` directly.
- **Only the explicit `Runtime.log/3`.** Rejected as the only form: every helper
  would have to take the runtime as an argument, and a helper called before a
  run has none.
- **Persist the lines next to the replay artifact,** so a report can be
  formatted again without a rerun. Rejected for now: artifacts get committed,
  and an unredacted line would be published. It could return later as an
  explicit opt-in.

## Open questions

- An environment variable (for example `PD_LOG="except:body"`) would let a
  reader change the display without editing the test, since `mix test` takes no
  custom flags. Not decided.
- The cap on lines kept per step, for commands retried many times by settle or
  stutter. Not decided.
