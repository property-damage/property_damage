# Log Lines in the Failure Report

`PropertyDamage.log/2` lets an adapter say what it did: the request it sent,
the answer it read, the rows it seeded before the run. PropertyDamage keeps
each line under the step whose code wrote it and prints it in the failure
report, beside that step's events. A line never reaches the console during a
run and never goes to Elixir's `Logger`, so a passing run prints nothing.

This guide builds a small example that fails, reads its report, and then
covers each part of the feature: the message forms, scopes, work done before
the run, tag filters, retried commands and where the lines live.

## Quickstart

The system under test is an in-memory bank whose `request/4` function answers
like an HTTP API. The bank has a planted bug: a withdrawal of 5 or more costs
a fee of 1, and the funds check forgets the fee. The adapter logs each request
and each answer, and the model checks that no balance goes below zero.

### 1. Create a project

```bash
mix new bank_logs
cd bank_logs
```

Replace the `deps` function in `mix.exs` (its commented example lines
included) with this one:

```elixir
defp deps do
  [
    {:property_damage, "~> 0.2"}
  ]
end
```

To use a local checkout of PropertyDamage instead, write
`{:property_damage, path: "/path/to/property_damage"}` in place of the
version. Then fetch it:

```bash
mix deps.get
```

### 2. Write the system, the adapter and the model

Create `lib/my_app.ex` with this content:

<!-- pd-example: lib/my_app.ex -->
<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Bank do
  @moduledoc """
  The system under test: an in-memory bank whose `request/4` answers like an
  HTTP API. It has a planted bug: a withdrawal of 5 or more costs a fee of 1,
  and the funds check forgets the fee.
  """

  def start, do: Agent.start(fn -> %{} end)

  def stop(bank), do: Agent.stop(bank)

  def request(bank, "POST", "/accounts/" <> path, %{"amount" => amount}) do
    [account, action] = String.split(path, "/")

    Agent.get_and_update(bank, fn balances ->
      balance = Map.get(balances, account, 0)

      case action do
        "deposit" -> credit(balances, account, balance + amount)
        "withdraw" when amount > balance -> {{422, %{"error" => "insufficient funds"}}, balances}
        "withdraw" -> credit(balances, account, balance - amount - fee(amount))
      end
    end)
  end

  defp fee(amount) when amount >= 5, do: 1
  defp fee(_amount), do: 0

  defp credit(balances, account, balance),
    do: {{200, %{"balance" => balance}}, Map.put(balances, account, balance)}
end

defmodule MyApp.Deposit do
  @moduledoc "Deposit `amount` into `account`."
  use PropertyDamage.Command

  defstruct [:account, :amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{account: StreamData.member_of(["alice", "bob"]), amount: StreamData.integer(1..9)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule MyApp.Withdraw do
  @moduledoc "Withdraw `amount` from `account`."
  use PropertyDamage.Command

  defstruct [:account, :amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{account: StreamData.member_of(["alice", "bob"]), amount: StreamData.integer(1..9)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule MyApp.BalanceChanged do
  @moduledoc "The balance the bank reported after a deposit or a withdrawal."
  defstruct [:account, :balance]
end

defmodule MyApp.WithdrawalRefused do
  @moduledoc "The bank refused a withdrawal."
  defstruct [:account]
end

defmodule MyApp.Adapter do
  @moduledoc "Sends each command to a bank of its own and logs the request and the answer."
  use PropertyDamage.Adapter
  require PropertyDamage

  @impl true
  def setup(config) do
    {:ok, bank} = MyApp.Bank.start()
    {:ok, %{bank: bank, token: Map.get(config, :token, "test-token")}}
  end

  @impl true
  def teardown(%{bank: bank}), do: MyApp.Bank.stop(bank)

  @impl true
  def execute(%MyApp.Deposit{account: account, amount: amount}, ctx, _runtime),
    do: post(ctx, account, "deposit", amount)

  def execute(%MyApp.Withdraw{account: account, amount: amount}, ctx, _runtime),
    do: post(ctx, account, "withdraw", amount)

  defp post(ctx, account, action, amount) do
    path = "/accounts/#{account}/#{action}"
    headers = %{"authorization" => "Bearer " <> ctx.token}
    body = %{"amount" => amount}

    PropertyDamage.log("POST #{path}", tags: [:http, :url])
    PropertyDamage.log(redact(headers), tags: [:http, :headers])
    PropertyDamage.log(body, tags: [:http, :body])

    {status, response} = MyApp.Bank.request(ctx.bank, "POST", path, body)

    PropertyDamage.log("-> #{status}", tags: [:http, :status])
    PropertyDamage.log(response, tags: [:http, :response])

    case status do
      200 -> {:ok, [%MyApp.BalanceChanged{account: account, balance: response["balance"]}]}
      422 -> {:ok, [%MyApp.WithdrawalRefused{account: account}]}
    end
  end

  # The caller redacts: the report prints a line exactly as it was given.
  defp redact(headers), do: Map.replace(headers, "authorization", "[REDACTED]")
end

defmodule MyApp.Balances do
  @moduledoc "Folds the balances the bank reported and checks that none is negative."
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, %MyApp.BalanceChanged{account: account, balance: balance}),
    do: Map.put(state, account, balance)

  def apply(state, _event), do: state

  @check every: 1
  def never_negative(state, _command_or_event),
    do: Enum.all?(state, fn {_account, balance} -> balance >= 0 end)
end

defmodule MyApp.Model do
  @moduledoc "Deposits and withdrawals on two accounts."
  @behaviour PropertyDamage.Model

  @impl true
  def commands, do: [MyApp.Deposit, MyApp.Withdraw]

  @impl true
  def command_sequence_projection, do: MyApp.Balances

  @impl true
  def check_projections, do: [MyApp.Balances]
end
```

The adapter logs five lines per command, each under two tags. `require
PropertyDamage` comes first, because `PropertyDamage.log/2` is a macro: it
records the file and line of the call.

### 3. Run it

Create `bug.exs` in the project root:

<!-- pd-example: bug.exs -->
<!-- pd-doc-verify: runnable -->
```elixir
{:error, report} =
  PropertyDamage.run(
    model: MyApp.Model,
    targets: [MyApp.Adapter],
    max_runs: 50,
    seed: 20
  )

IO.inspect(report, pretty: true)
```

```bash
mix run bug.exs
```

With seed 20, the run fails, shrinks the failure to two commands and prints
the report. Another seed finds the bug in another run, and its shrunk
reproduction may keep more commands, though none of them can be dropped alone
without losing the failure:

<!-- pd-report-excerpt: mix run bug.exs; seed 20 -->
```text
#FailureReport<
╔══════════════════════════════════════════════════════════════════════╗
║                            BUG DETECTED!                             ║
╚══════════════════════════════════════════════════════════════════════╝

Seed: 20

## Failure

Failure  check failed
Check    never_negative
At       [1] %MyApp.Withdraw{account: "alice", amount: 5}
Message  check `never_negative` returned `false`; a check passes by returning a truthy value: a predicate, `condition or fail!(...)`, or a body that ends with `:ok`

## Minimal Reproduction (2 roots)

  [0] %MyApp.Deposit{account: "alice", amount: 5}
        +0.00s log   [http url] POST /accounts/alice/deposit
        +0.00s log   [http headers] %{"authorization" => "[REDACTED]"}
        +0.00s log   [http body] %{"amount" => 5}
        +0.00s log   [http status] -> 200
        +0.00s log   [http response] %{"balance" => 5}
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: 5}
► [1] %MyApp.Withdraw{account: "alice", amount: 5}  ◄── failed
        +0.00s log   [http url] POST /accounts/alice/withdraw
        +0.00s log   [http headers] %{"authorization" => "[REDACTED]"}
        +0.00s log   [http body] %{"amount" => 5}
        +0.00s log   [http status] -> 200
        +0.00s log   [http response] %{"balance" => -1}
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: -1}

## Projections at [1]   (- before, + after)

MyApp.Balances   last applied: BalanceChanged
  - "alice" => 5
  + "alice" => -1

## Reproduction

targets = [MyApp.Adapter]

# Rerun from the seed:
PropertyDamage.run(model: MyApp.Model, targets: targets, seed: 20, max_runs: 1)

# Regenerate the failing variant:
PropertyDamage.Expansion.for(MyApp.Model, 20, 1, "Adapter")

# Replay the shrunk failure:
PropertyDamage.run(model: MyApp.Model, targets: targets, only: [replay: "property_damage_replays/Model_seed20.replay.exs"])
>
```

`IO.inspect/2` wraps the report in `#FailureReport<` and `>`. Read it from the
top. The Failure section names the check and the step that
broke it, `[1]`. Under each step of Minimal Reproduction, the step's log lines
and events print in the order they happened. Each entry starts with its
offset from the start of the target's run (`+0.00s`, since the bank answers
at once), then `log` or `event`, then the line's tags in brackets and its
message. The lines show what the adapter sent and what the bank answered: a
withdrawal of 5 from a balance of 5 came back `200` with a balance of `-1`.
The `authorization` header reads `[REDACTED]` because the adapter redacted it
before the call.

### 4. Read the report through a tag filter

Five lines per step is a lot once a run has many steps. The environment
variable `PD_LOG` chooses which tagged lines to show, without a code change.
Run the same script and show only the request line and the status:

```bash
PD_LOG="only:url,status" mix run bug.exs
```

<!-- pd-report-excerpt: PD_LOG="only:url,status" mix run bug.exs; seed 20 -->
```text
#FailureReport<
╔══════════════════════════════════════════════════════════════════════╗
║                            BUG DETECTED!                             ║
╚══════════════════════════════════════════════════════════════════════╝

Seed: 20

## Failure

Failure     check failed
Check       never_negative
At          [1] %MyApp.Withdraw{account: "alice", amount: 5}
Message     check `never_negative` returned `false`; a check passes by returning a truthy value: a predicate, `condition or fail!(...)`, or a body that ends with `:ok`
Log filter  only: [:url, :status] (from PD_LOG)

## Minimal Reproduction (2 roots)

  [0] %MyApp.Deposit{account: "alice", amount: 5}
        +0.00s log   [http url] POST /accounts/alice/deposit
        +0.00s log   [http status] -> 200
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: 5}
► [1] %MyApp.Withdraw{account: "alice", amount: 5}  ◄── failed
        +0.00s log   [http url] POST /accounts/alice/withdraw
        +0.00s log   [http status] -> 200
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: -1}

## Projections at [1]   (- before, + after)

MyApp.Balances   last applied: BalanceChanged
  - "alice" => 5
  + "alice" => -1

## Reproduction

targets = [MyApp.Adapter]

# Rerun from the seed:
PropertyDamage.run(model: MyApp.Model, targets: targets, seed: 20, max_runs: 1)

# Regenerate the failing variant:
PropertyDamage.Expansion.for(MyApp.Model, 20, 1, "Adapter")

# Replay the shrunk failure:
PropertyDamage.run(model: MyApp.Model, targets: targets, only: [replay: "property_damage_replays/Model_seed20.replay.exs"])
>
```

The headers, bodies and responses are hidden, and the Failure section's
`Log filter` field says which filter applied and where it came from.
[Filtering by tag](#filtering-by-tag) covers the rules.

## Writing a line

`PropertyDamage.log(message, opts \\ [])` is a macro, so a module calls
`require PropertyDamage` before its first call. `opts` takes one key, `tags:`,
a literal list of atoms. Any other key, a tag that is not an atom, or options
that are not a literal keyword list stop the module from compiling.

A message takes one of three forms:

| Form | When it is turned into text | How it prints |
|------|-----------------------------|---------------|
| a string | at the call | as written |
| any other value | when the report is formatted | `inspect(value, pretty: true)`, colored in a colored report |
| a 0-arity function | when the report is formatted | its result, by the two rules above |

A value is stored as it was at the call. Elixir values do not change, so the
report shows the value the adapter had.

A function is different, and it is a trap. PropertyDamage calls it when the
report is formatted, after the run has ended. If the function reads something
that can change, such as an `Agent`, an ETS table or another process, it reads
the state at the end of the run, not at the call. If that process is gone, as
the bank is after the adapter's `teardown/1`, the function fails. The report
then prints `(log line raised: ` followed by the error, in place of the line.
Use a function only for work that is costly and reads nothing that changes,
such as decoding a response body the line already holds:

```elixir
PropertyDamage.log(fn -> Jason.decode!(raw_body) end, tags: [:http, :response])
```

The macro never wraps a message in a function on its own. A run that passes
never formats a value and never calls a function, so logging large terms
costs little on a passing run.

## Scopes

Every call needs a scope: a place for the line to land. PropertyDamage opens
one before it runs your code at an execution point, which is any of these:

- an adapter's `setup/1`, `execute/3` and `teardown/1`;
- each setup and teardown command, each root and each leaf, and each attempt
  of a settle or stutter retry;
- a nemesis's `inject/2` and `restore/2`;
- a mock's setup and its `on_command/2` and `on_event/2` handlers.

`PropertyDamage.log/2` looks for a scope in the calling process first, then in
each process of the caller's `$callers` list. A `Task` started from
`execute/3` therefore logs to the step that started it, because `Task` puts
its parent in `$callers`. That holds also when a `Task` between them has
exited while the step runs. The step's scope lives in the process that runs
`execute/3`, which exits when the step ends. So a process left running by a
step that has ended finds no scope, and its line never lands under a later
step.

A call that finds no scope raises `PropertyDamage.Log.NoScopeError`. Inside
`execute/3` the raise becomes an adapter error, and the report classifies it
as a test code error, not as a bug in the system under test. Code that
PropertyDamage does not run at an execution point, such as a projection, a
check or a generator, has no scope.

The error names the call site, the calling process and the three fixes:
call the code from a scope, wrap it in `PropertyDamage.Log.capture/1`, or log
through `PropertyDamage.Runtime.log/3`. [Work done before the
run](#work-done-before-the-run) shows the error and the `capture/1` fix.

### Processes the adapter does not start through `Task`

A `GenServer` that the adapter calls has no scope of its own, and its
`$callers` list does not lead back to the step. It logs through the
`%PropertyDamage.Runtime{}` that `execute/3` received, with
`PropertyDamage.Runtime.log/3`. Pass the runtime along in the call:

```elixir
# In the adapter:
def execute(%MyApp.Charge{amount: amount}, ctx, runtime) do
  :ok = GenServer.call(ctx.charger, {:charge, runtime, amount})
  {:ok, [%MyApp.Charged{amount: amount}]}
end

# In the GenServer:
def handle_call({:charge, runtime, amount}, _from, state) do
  PropertyDamage.Runtime.log(runtime, "charging #{amount}", tags: [:charge])
  {:reply, :ok, state}
end
```

`Runtime.log/3` takes the same message forms and the same `tags:` option, and
it writes to the same place as `PropertyDamage.log/2`. It checks its options
when it runs, not at compile time, and it does not record the call site.

### The `$callers` lookup and the OTP version

The lookup reads one key of another process's dictionary, which needs OTP 26.2
or later. On an older OTP, PropertyDamage falls back to reading each such
process's whole dictionary. The result is the same; the fallback costs more
per call when a `Task` logs.

## Work done before the run

Some setup happens once, before the run starts: a test seeds a database or
logs in, often in an ExUnit `setup_all`. Its lines matter when a failure
depends on that setup, but there is no run yet to hold them. `Log.capture/1`
gives that code a scope, and the run's `setup_log:` option hands its lines to
the report.

Create `lib/my_app/auth.ex`, a login helper that logs:

<!-- pd-example: lib/my_app/auth.ex -->
<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Auth do
  @moduledoc "Logs in before a run and returns the token the adapter sends."
  require PropertyDamage

  def login!(user) do
    PropertyDamage.log("POST /login as #{user}", tags: [:http, :url])
    PropertyDamage.log("-> 200, token issued", tags: [:http, :status])
    "token-for-" <> user
  end
end
```

Code outside a run has no scope, so calling `MyApp.Auth.login!/1` from plain
code raises. Create `no_scope.exs` to see the error:

<!-- pd-example: no_scope.exs -->
<!-- pd-doc-verify: runnable -->
```elixir
try do
  MyApp.Auth.login!("alice")
rescue
  error in PropertyDamage.Log.NoScopeError -> IO.puts(Exception.message(error))
end
```

```bash
mix run no_scope.exs
```

<!-- pd-report-excerpt: mix run no_scope.exs -->
```text
PropertyDamage.log/2 found no scope at lib/my_app/auth.ex:6 in process #PID<0.95.0>.
A log line lands only in a scope, and neither this process nor any process in its $callers holds one. Fix it in one of three ways:
  * call it from code PropertyDamage runs (an adapter callback, a command, a nemesis or mock handler);
  * wrap the code in PropertyDamage.Log.capture/1;
  * log through PropertyDamage.Runtime.log/3 with the runtime the adapter was handed.
```

`capture/1` is the fix for code like this. Create `setup.exs`:

<!-- pd-example: setup.exs -->
<!-- pd-doc-verify: runnable -->
```elixir
{token, setup_log} = PropertyDamage.Log.capture(fn -> MyApp.Auth.login!("alice") end)

{:error, report} =
  PropertyDamage.run(
    model: MyApp.Model,
    targets: [{MyApp.Adapter, config: %{token: token}}],
    max_runs: 50,
    seed: 20,
    setup_log: setup_log,
    log: [only: [:url]]
  )

IO.inspect(report, pretty: true)
```

```bash
mix run setup.exs
```

`capture/1` runs the function, and returns its result and the lines it
logged. The report prints those lines once, in a Setup section after
Failure, labeled as shared by every run:

<!-- pd-report-excerpt: mix run setup.exs; seed 20 -->
```text
#FailureReport<
╔══════════════════════════════════════════════════════════════════════╗
║                            BUG DETECTED!                             ║
╚══════════════════════════════════════════════════════════════════════╝

Seed: 20

## Failure

Failure     check failed
Check       never_negative
At          [1] %MyApp.Withdraw{account: "alice", amount: 5}
Message     check `never_negative` returned `false`; a check passes by returning a truthy value: a predicate, `condition or fail!(...)`, or a body that ends with `:ok`
Log filter  only: [:url] (from the log: option)

## Setup

  Logged before the run, shared by every run
        +0.00s log   [http url] POST /login as alice

## Minimal Reproduction (2 roots)

  [0] %MyApp.Deposit{account: "alice", amount: 5}
        +0.00s log   [http url] POST /accounts/alice/deposit
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: 5}
► [1] %MyApp.Withdraw{account: "alice", amount: 5}  ◄── failed
        +0.00s log   [http url] POST /accounts/alice/withdraw
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: -1}

## Projections at [1]   (- before, + after)

MyApp.Balances   last applied: BalanceChanged
  - "alice" => 5
  + "alice" => -1

## Reproduction

targets = [{MyApp.Adapter, config: %{token: "token-for-alice"}}]

# Rerun from the seed:
PropertyDamage.run(model: MyApp.Model, targets: targets, seed: 20, max_runs: 1)

# Regenerate the failing variant:
PropertyDamage.Expansion.for(MyApp.Model, 20, 1, "Adapter")

# Replay the shrunk failure:
PropertyDamage.run(model: MyApp.Model, targets: targets, only: [replay: "property_damage_replays/Model_seed20.replay.exs"])
>
```

The Setup section takes the same tag filter as every other line, here the
`log: [only: [:url]]` the script gave in code. A capture nested inside another
keeps its own lines, and the outer one gets none of them. A raise inside the
function propagates, and the lines written before it are dropped.

In an ExUnit test, capture in `setup_all` and pass the lines to the run. Save
this as `test/bank_test.exs` and run `mix test`; with the planted bug, the
test fails and prints the report:

```elixir
defmodule MyApp.BankTest do
  use ExUnit.Case

  setup_all do
    {token, setup_log} = PropertyDamage.Log.capture(fn -> MyApp.Auth.login!("alice") end)
    %{token: token, setup_log: setup_log}
  end

  test "no balance goes negative", %{token: token, setup_log: setup_log} do
    case PropertyDamage.run(
           model: MyApp.Model,
           targets: [{MyApp.Adapter, config: %{token: token}}],
           setup_log: setup_log,
           log: [except: [:headers]]
         ) do
      {:ok, _stats} -> :ok
      {:error, report} -> flunk(PropertyDamage.ExUnit.format_failure(report))
    end
  end
end
```

`PropertyDamage.ExUnit.format_failure/2` prints the report with color.

## Filtering by tag

Tags are the only display filter. A run, a replay call and
`PropertyDamage.ExUnit.format_failure/2` take `log: [only: tags, except:
tags]`:

- `only:` shows the tagged lines that carry any listed tag.
- A line with no tags always shows.
- `except:` hides the lines that carry any listed tag, and wins over `only:`.
- A filter hides whole lines. It never cuts part of a line, and hiding a line
  does not move any other line's offset.

A tag that the filter lists and no line of the report carries is named in a
`Log warning` field of the Failure section, so a misspelled tag does not read
as "nothing happened". The `Log filter` field prints the filter that applied
and its source, `(from the log: option)` or `(from PD_LOG)`.

To show the parts of a request separately, log each part in its own call
under its own tag, as the quickstart adapter does with `:url`, `:headers`,
`:body`, `:status` and `:response`. The reader then combines tags.

### `PD_LOG`

`PD_LOG` holds the same filter as text, for one command:

```bash
PD_LOG="only:http,seed except:body" mix test
```

- A part is `only:` or `except:` followed by comma-separated tag names. Parts
  are separated by spaces, each key appears at most once, and each part needs
  at least one tag. An empty value counts as unset.
- When `PD_LOG` is set, it replaces the `log:` filter given in code. The two
  never merge.
- It applies to every report formatted in that process: a test run, a replay
  call and `format_failure/2`.
- PropertyDamage reads it only when it formats a report. It cannot change a
  verdict, a shrink or a replay artifact.
- If the value does not parse, `format_failure/2` and a failing
  `property_damage` test raise an `ArgumentError` that shows the expected
  syntax.
  `IO.inspect(report, pretty: true)` does not raise: it prints a one-line
  summary in place of the report, and the summary ends with the error it
  replaced, here the `PD_LOG` syntax message.

### A finished report

`PropertyDamage.ExUnit.format_failure(report, log: [...])` formats a finished
report through another filter, which replaces the one the run gave. `log: []`
clears the run's filter and shows every line. The run itself does not accept
an empty list: `PropertyDamage.run/1` rejects `log: [only: []]` and
`log: [except: []]`, so give the run a filter only when you want one.
`keep_attempts:` belongs to the run alone; `format_failure/2` rejects it,
because it cannot change which lines a finished run kept.

### The Reproduction calls carry no filter

The rerun, regenerate and replay calls at the end of the report do not carry
the run's `log:` filter. A pasted call shows every line. To read the rerun
through the same filter, add the `log:` option from the `Log filter` field to
the call, or set `PD_LOG`.

### A filter is not redaction

A filter hides lines from one reader of one printed report. The hidden lines
are still in the report in memory, and the next reader can turn the filter
off. The code that calls `PropertyDamage.log/2` removes secrets before the
call, as the quickstart adapter's `redact/1` does.

## Retried commands

A settle or stutter retry can run one command hundreds of times, and each
attempt logs the same few lines. For each step, the run keeps the lines of the
first attempt and of the last three attempts. When a newer attempt pushes an
older one out of the last three, the run drops that attempt's lines and
counts them, so memory stays bounded. The report prints each gap in its
place, with its count. Here, a command that settled on its 300th attempt
logged two lines per attempt:

<!-- pd-report-excerpt: test/support/log_fixtures.ex SpinModel, 300 attempts, step [0]; seed 4242 -->
```text
        +0.00s log   spin attempt 1
        +0.00s log   spin detail 1
        ... 296 attempts omitted (592 lines)
        +0.00s log   spin attempt 298
        +0.00s log   spin detail 298
        +0.00s log   spin attempt 299
        +0.00s log   spin detail 299
        +0.00s log   spin attempt 300
        +0.00s log   spin detail 300
```

`log: [keep_attempts: n]` on the run keeps the last `n` attempts instead of
three. The cap drops whole attempts and never cuts a line or a value.
`PropertyDamage.shrink_further/2` and `PropertyDamage.Replay.start/2` take the
same option. A report does not record the run's value, so pass it again to
`shrink_further/2` when the run had one.

PropertyDamage knows an attempt only from the lines it writes. "The last
three attempts" therefore means the last three attempts that logged a line.
An attempt that logged nothing is invisible to the cap and leaves no gap.

## Where lines print

- A step's lines and events print under the step, in timestamp order, each
  with its offset from the earliest entry of the target's own run.
- Lines from an adapter's `setup/1` print before the first step of that
  target's listing, and lines from `teardown/1` after the last step.
- For a comparison failure (`:diverged`, `:did_not_converge`), the report lists
  the reference and the failing variant, each with its own lines.
- A root listed after the failing step that never ran prints with no lines
  and no events. That root did not run; its lines are not lost.

## Lines live in memory only

A run's lines are dropped when the run ends, unless the run is the one
reported. PropertyDamage never writes a line to a replay artifact, a saved
report or trace, or any other file: those files get committed, and a line the
caller forgot to redact would be published.

So a report loaded from a file shows no lines. To see them again, run the
replay call from the report's Reproduction section; it runs the failure again
and collects new lines. A replay that does not reproduce the failure shows no
lines for it.

## Next steps

- [Debugging Failures](debugging_failures.md) - read and reproduce the rest of
  the report
- `PropertyDamage.Log` - scopes, storage and the retry cap in detail
- `PropertyDamage.Log.Filter` - the filter and `PD_LOG` grammar
