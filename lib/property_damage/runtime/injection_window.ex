defmodule PropertyDamage.Runtime.InjectionWindow do
  @moduledoc """
  The per-command injection-sink *window* lifecycle (DR-027), extracted so it
  lives in exactly one place.

  Every path that executes a single command against an adapter opens the same
  window: start a `PropertyDamage.Runtime.Sink`, seed it, build the `%Runtime{}`
  the adapter receives (its `inject`/`start_poller` closures accumulate into the
  sink), run the execution, then drain the accumulated context and pollers and
  stop the sink. Before this module that boilerplate was copied three times (the
  executor's `execute_regular_command`, `Differential`, and `LoadTest.Worker`),
  so a change to the sink mechanism had to be made in three places and drifted.

  What stays *caller-specific* is deliberately not captured here, because it
  legitimately differs between paths:

    * the sink's initial context and how `inject` folds into it. The engine seeds
      a rich context (`:projections`, `:event_log`, ...) and folds projections in
      real time; the differential and load-test paths seed `%{events: []}` and
      just accumulate the raw injected events.
    * the `start_poller` policy. The engine starts real resource pollers; the
      differential and load-test paths raise, having no poller support.
    * how the adapter is actually invoked (directly, via settle, or wrapped in a
      timeout task).

  Those are supplied by the caller through `build_runtime` and `execute_fn`.

  The sink is always stopped, even if `execute_fn` raises, so an adapter that
  throws mid-execution cannot leak the sink `Agent`.
  """

  alias PropertyDamage.Runtime

  @doc """
  Open a per-command injection window and run `execute_fn` inside it.

  Returns `{result, final_ctx, pollers}` where `result` is `execute_fn`'s return
  value, `final_ctx` is the sink context after execution (the caller drains what
  it seeded, e.g. `final_ctx.events` or `final_ctx.injected_events`), and
  `pollers` are any resource pollers registered during execution (empty for paths
  whose `start_poller` raises).

  Arguments:

    * `initial_ctx` - the map used to seed the sink via `Sink.put_ctx/2`.
    * `build_runtime` - a 1-arity function given the sink pid; it returns the
      `%PropertyDamage.Runtime{}` handed to the adapter. It runs in the calling
      process, so closures such as the engine's `start_poller` capture `self/0`
      as the poller owner exactly as before.
    * `execute_fn` - a 1-arity function given that runtime; it performs the
      adapter execution and returns the result the caller cares about.
  """
  @spec run(map(), (pid() -> Runtime.t()), (Runtime.t() -> result)) ::
          {result, map() | nil, [term()]}
        when result: var
  def run(initial_ctx, build_runtime, execute_fn)
      when is_function(build_runtime, 1) and is_function(execute_fn, 1) do
    {:ok, sink} = Runtime.Sink.start_link()

    try do
      Runtime.Sink.put_ctx(sink, initial_ctx)
      runtime = build_runtime.(sink)
      result = execute_fn.(runtime)
      {result, Runtime.Sink.get_ctx(sink), Runtime.Sink.get_pollers(sink)}
    after
      Runtime.Sink.stop(sink)
    end
  end

  @doc """
  Open a window for a path that only *accumulates* injected events and has no
  resource-poller support (the differential and load-test paths).

  Seeds the sink with `%{events: []}`, hands the adapter a runtime whose `inject`
  appends raw events and whose `start_poller` raises `ArgumentError` with
  `poller_error`, then returns `{result, injected_events}` where `injected_events`
  is in injection order. This is the lean counterpart to `run/3`, which the engine
  uses when its `inject` must fold projections in real time.
  """
  @spec run_accumulating((Runtime.t() -> result), String.t()) :: {result, [term()]}
        when result: var
  def run_accumulating(execute_fn, poller_error) when is_function(execute_fn, 1) do
    build_runtime = fn sink ->
      %Runtime{
        inject: fn event ->
          Runtime.Sink.update_ctx(sink, fn ctx -> %{ctx | events: [event | ctx.events]} end)
        end,
        start_poller: fn _opts -> raise ArgumentError, poller_error end
      }
    end

    {result, final_ctx, _pollers} = run(%{events: []}, build_runtime, execute_fn)
    {result, Enum.reverse(final_ctx.events)}
  end
end
