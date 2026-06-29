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
  """

  @type ctx :: map()

  @spec start_link() :: {:ok, pid()}
  def start_link, do: Agent.start_link(fn -> %{ctx: nil, pollers: []} end)

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
end
