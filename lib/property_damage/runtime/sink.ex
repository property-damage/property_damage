defmodule PropertyDamage.Runtime.Sink do
  @moduledoc """
  Explicit, process-independent accumulator for one command's mid-execution event
  injection and resource-poller tracking (DR-027).

  Replaces the executor's former `@injection_ctx_key` / `@resource_pollers_key`
  **process-dictionary** channels. The sink is an `Agent` referenced by pid and
  handed to the per-command `inject` / `start_poller` closures, so those closures
  accumulate correctly even when the adapter runs `execute` in a *spawned* process
  (e.g. a load-test worker's `Task`), where the process dictionary did not carry
  across the process boundary.

  ## Injection context

  `put_ctx/2` seeds the per-command context the executor's `inject` folds into:

      %{
        projections: projections,      # folded in real time as events are injected
        event_log: event_log,          # newest-first; injected entries prepended
        injected_events: [],           # injection order (for external() capture, DR-021)
        command_index: index,
        branch_id: branch_id,
        command: command
      }

  The fold itself runs in the **caller** process (see `Executor.inject_event/2`),
  not inside the Agent, so a projection `apply/2` that raises a transition-invariant
  violation propagates into the adapter exactly as before; the sink only stores the
  already-computed result via `update_ctx/2`.

  ## Log lines

  The sink also holds the log lines the command writes (DR-054):
  `PropertyDamage.log/2` and `PropertyDamage.Runtime.log/3` add each line at the
  call with `add_line/2`, a synchronous call, so a line written before a
  timeout kills the command's `Task` is still here when the engine reads the
  lines back with `lines/1`.

  The sink applies the retry cap as the lines arrive (`PropertyDamage.Log.Cap`):
  it keeps the lines of the command's first attempt and of its last
  `keep_attempts` attempts, and drops the lines of an older attempt as soon as
  a newer one pushes it out, counting them in one `PropertyDamage.Log.Gap`.
  So a 1,000-attempt settle never holds the lines of more than
  `keep_attempts + 1` attempts. `attempts_held/1` reports how many it holds.
  `lines/1` returns the kept lines in order, the gap between the first
  attempt's lines and the others.

  `start_link/1` takes `keep_attempts:` (default
  `PropertyDamage.Log.Cap.default_keep_attempts/0`). The stutter retries of a
  command run after its own sink closed, and write into a sink that continues
  the step's kept lines: `lines:` seeds it with the list `lines/1` returned for
  the step, and `phase: :stutter` keys its attempts apart from the command's,
  whose numbers they share.
  """

  alias PropertyDamage.Log.Cap

  @type ctx :: map()

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    keep = Keyword.get(opts, :keep_attempts, Cap.default_keep_attempts())
    cap = Cap.new(keep, Keyword.get(opts, :phase, :command), Keyword.get(opts, :lines, []))
    Agent.start_link(fn -> %{ctx: nil, pollers: [], cap: cap} end)
  end

  @spec stop(pid()) :: :ok
  def stop(pid), do: Agent.stop(pid)

  @doc "Seed the per-command injection context."
  @spec put_ctx(pid(), ctx()) :: :ok
  def put_ctx(pid, ctx), do: Agent.update(pid, fn s -> %{s | ctx: ctx} end)

  @doc "Read the accumulated injection context (or `nil` if none has been seeded)."
  @spec get_ctx(pid()) :: ctx() | nil
  def get_ctx(pid), do: Agent.get(pid, & &1.ctx)

  @doc """
  Replace the injection context with `fun.(current_ctx)`.

  `fun` must be pure (it runs in the Agent process); compute anything that can
  raise in the caller and pass the result in.
  """
  @spec update_ctx(pid(), (ctx() -> ctx())) :: :ok
  def update_ctx(pid, fun), do: Agent.update(pid, fn s -> %{s | ctx: fun.(s.ctx)} end)

  @doc "Track a resource poller started during this command (newest-first)."
  @spec add_poller(pid(), term()) :: :ok
  def add_poller(pid, poller),
    do: Agent.update(pid, fn s -> %{s | pollers: [poller | s.pollers]} end)

  @doc "All resource pollers started during this command (newest-first)."
  @spec get_pollers(pid()) :: [term()]
  def get_pollers(pid), do: Agent.get(pid, & &1.pollers)

  @doc "Add one log line (DR-054); the retry cap drops an older attempt's lines when it must."
  @spec add_line(pid(), PropertyDamage.Log.Line.t()) :: :ok
  def add_line(pid, line), do: Agent.update(pid, fn s -> %{s | cap: Cap.add(s.cap, line)} end)

  @doc """
  The log lines this sink keeps, in the order they were written: the first
  attempt's, a `PropertyDamage.Log.Gap` when the cap dropped lines, then the
  last attempts'.
  """
  @spec lines(pid()) :: [PropertyDamage.Log.Line.t() | PropertyDamage.Log.Gap.t()]
  def lines(pid), do: Agent.get(pid, &Cap.lines(&1.cap))

  @doc "How many attempts' lines this sink holds right now."
  @spec attempts_held(pid()) :: non_neg_integer()
  def attempts_held(pid), do: Agent.get(pid, &Cap.attempts_held(&1.cap))
end
