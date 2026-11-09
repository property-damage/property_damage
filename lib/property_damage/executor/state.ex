defmodule PropertyDamage.Executor.State do
  @moduledoc """
  Typed run-state for `PropertyDamage.Executor` (DR-029).

  Built once per run by `PropertyDamage.Executor.Step.new_state/2` (also through
  `PropertyDamage.Executor.Stepping.init_state/2`), then threaded through the
  per-command engine and the finalize chain.

  This replaces the former untyped flat map. With the step's state writes going
  through `struct!/2` and the in-loop updates using struct-update syntax, a write to an
  **undeclared** field now raises instead of silently producing a corrupt
  struct-shaped map (`Map.merge/2` onto a struct does not raise). A field
  that previously existed only as a "ghost" (entering solely via `Map.put`
  writes and `Map.get(state, k, default)` reads, never initialized in
  `PropertyDamage.Executor.Step.new_state/2`) is declared here with an explicit default:
  `:async_halt`.

  ## Fields

  Run identity / configuration (provided at construction):

    * `:model` - the model module
    * `:event_queue` - `EventQueue` pid for injector/poller events (or `nil`)
    * `:check_mode` - `:halt | :record | :log | :disabled`
    * `:stutter_config` - stutter configuration (or `nil`)
    * `:mock_registry` - mock service registry pid (or `nil`)
    * `:external_markers` - declared `external()` marker atoms
    * `:command_specs` - `%{command_module => resolved_spec}` (built once)
    * `:placeholder_registry` - DR-021 id-indexed placeholder registry
    * `:rng_seed` - integer seed for explicit stutter RNG (DR-029); the executor
      derives a per-command generator from `{rng_seed, command_index}`. `nil`
      collapses to a fixed base so draws stay deterministic.

  Evolving run state:

    * `:event_log` - reversed (newest-first) list of recorded entries
    * `:projections` - `%{projection_module => state}`
    * `:projections_before` - snapshot of projections before the current command
    * `:current_position` - structured position of the executing command (DR-021)
    * `:executed` - `%{Sequence.Position => command}` of the concrete resolved
      commands actually sent to the adapter, keyed by position (DR-033). Feeds
      `RunTrace.executed`; always accumulated.
    * `:run_nonce` - the 64-bit run nonce (DR-034) seeding `mint_per_run`
      resolution; `nil` when the run declared no minted values.
    * `:mint_epoch` - which SUT execution within a logical run this is (DR-034);
      `0` for the recorded run, incremented per shrink attempt / replay.
    * `:step_count` - number of commands executed
    * `:check_counters` - `%{step:, command:, event:, ...}` firing counts
    * `:check_failures` - accumulated `:record`-mode failures (newest-first)
    * `:active_pollers` - running `@eventually` pollers
    * `:active_resource_pollers` - running resource pollers
    * `:async_halt` - `{name, projection, reason, command_index}` set when a DR-025 async
      `every:` check trips during a `@eventually` await drain (ghost field)
    * `:async_failed_index` - the command index a DR-025 async `every:` check
      failure is attributed to (the offending event's `command_index`, which may
      be an earlier command than the one currently executing, or `nil` for an
      ambient injector event). `:unset` on every non-failing state; consulted by
      finalization so the report names the right command (ghost field).
    * `:await_matchers` - DR-030 correlation registry: a registration-ordered
      list of `%{command_index:, match:}` declared via
      `Command.awaits/2`. Persists for the rest of the run (a matcher outlives
      the command that declared it) so late injector events still correlate.
      First-registered wins when several match one event.
    * `:fold_counter` - the next per-run fold ordinal (DR-040). Every event
      folded into projections stamps its `EventLog.Entry.fold_index` with the
      current value and advances it; every command fold records the current value
      in `:command_fold_ordinals` before advancing. Monotonic across the whole
      run so the faithful per-step state timeline can replay the true fold order.
    * `:command_fold_ordinals` - `%{Sequence.Position => fold ordinal}` recording
      the ordinal at which each command was itself folded into projections (the
      command fold has no `EventLog.Entry` of its own, so its ordinal is homed
      here). Feeds `RunTrace.command_fold_ordinals`.
    * `:last_execute_us` - wall-clock microseconds the adapter's `execute/3`
      took for the most recent command, every settle attempt and the waits
      between them included; `nil` when that command never reached the adapter
      (an unresolved placeholder). Written on every command:
      two monotonic clock reads, so a run that ignores it pays nothing
      measurable. `PropertyDamage.Variant` reads it for latency comparison.
    * `:last_command_index` - the index of the most recent command (`{:setup,
      offset}` for a setup command); a mock event flushed between commands is
      attributed to it. `nil` before the first command.
    * `:on_resource_poller_start` - `nil` or a 1-arity function the engine
      calls with each resource poller's pid as soon as `runtime.start_poller`
      started it, before control returns to the adapter. A resource poller is
      linked to the process that started it (a per-command Task), so an owner
      that must reap every poller even when it is killed mid-command
      (`PropertyDamage.Variant`) learns of it here. `nil` everywhere else.
    * `:logs` - the log lines the run's user code wrote (DR-054), by the step
      they belong to (`PropertyDamage.Log`): a `Sequence.Position` for a
      command, `:adapter_setup` or `:adapter_teardown` for the adapter's
      `setup/1` or `teardown/1`. Each list is in the order written. Feeds
      `RunTrace.logs`.
    * `:keep_attempts` - how many of a step's last settle or stutter attempts
      keep their log lines, besides the first attempt's (`log: [keep_attempts: n]`,
      DR-054 decision 13).
    * `:telemetry` - `nil`, or the context command and check telemetry is
      emitted with (`%{variant: %{index, name}, run_number: n}`, see
      `PropertyDamage.Telemetry`); `nil` when nothing listens.
  """

  alias PropertyDamage.Log.Cap

  @enforce_keys [
    :model,
    :event_queue,
    :check_mode,
    :stutter_config,
    :mock_registry,
    :external_markers,
    :command_specs,
    :placeholder_registry
  ]
  # The state is the whole record of a run in progress, so it holds more
  # fields than the struct-size check allows.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :model,
    :event_queue,
    :check_mode,
    :stutter_config,
    :mock_registry,
    :external_markers,
    :command_specs,
    :placeholder_registry,
    rng_seed: nil,
    event_log: [],
    projections: %{},
    projections_before: nil,
    current_position: nil,
    executed: %{},
    run_nonce: nil,
    mint_epoch: 0,
    step_count: 0,
    check_counters: %{step: 0, command: 0, event: 0},
    check_failures: [],
    active_pollers: [],
    active_resource_pollers: [],
    async_halt: nil,
    async_failed_index: :unset,
    await_matchers: [],
    fold_counter: 0,
    command_fold_ordinals: %{},
    last_execute_us: nil,
    last_command_index: nil,
    on_resource_poller_start: nil,
    logs: %{},
    keep_attempts: Cap.default_keep_attempts(),
    telemetry: nil
  ]

  @type t :: %__MODULE__{
          model: module(),
          event_queue: pid() | nil,
          check_mode: atom(),
          stutter_config: term(),
          mock_registry: pid() | nil,
          external_markers: list(),
          command_specs: map(),
          placeholder_registry: term(),
          rng_seed: integer() | nil,
          event_log: list(),
          projections: map(),
          projections_before: map() | nil,
          current_position: term(),
          executed: %{term() => struct()},
          run_nonce: non_neg_integer() | nil,
          mint_epoch: non_neg_integer(),
          step_count: non_neg_integer(),
          check_counters: map(),
          check_failures: list(),
          active_pollers: list(),
          active_resource_pollers: list(),
          async_halt: term(),
          async_failed_index: non_neg_integer() | nil | :unset,
          await_matchers: [map()],
          fold_counter: non_neg_integer(),
          command_fold_ordinals: %{term() => non_neg_integer()},
          last_execute_us: non_neg_integer() | nil,
          last_command_index: non_neg_integer() | {:setup, non_neg_integer()} | nil,
          on_resource_poller_start: (pid() -> term()) | nil,
          logs: PropertyDamage.Log.logs(),
          keep_attempts: pos_integer(),
          telemetry: map() | nil
        }

  # ============================================================================
  # Reads
  # ============================================================================

  @doc "The projection states, by projection module."
  @spec projections(t()) :: map()
  def projections(%__MODULE__{projections: projections}), do: projections

  @doc "The log lines the run's user code wrote, by the step they belong to (DR-054)."
  @spec logs(t()) :: PropertyDamage.Log.logs()
  def logs(%__MODULE__{logs: logs}), do: logs

  @doc "The recorded event-log entries, newest first."
  @spec event_log(t()) :: list()
  def event_log(%__MODULE__{event_log: event_log}), do: event_log

  @doc "The next fold ordinal of the run (DR-040)."
  @spec fold_counter(t()) :: non_neg_integer()
  def fold_counter(%__MODULE__{fold_counter: fold_counter}), do: fold_counter

  @doc "The resolved commands sent to the adapter, by position (DR-033)."
  @spec executed(t()) :: %{term() => struct()}
  def executed(%__MODULE__{executed: executed}), do: executed

  @doc "The check firing counters."
  @spec check_counters(t()) :: map()
  def check_counters(%__MODULE__{check_counters: counters}), do: counters

  @doc "The recorded `:record`-mode check failures, newest first."
  @spec check_failures(t()) :: list()
  def check_failures(%__MODULE__{check_failures: failures}), do: failures

  @doc "The fold ordinal of each command, by position (DR-040)."
  @spec command_fold_ordinals(t()) :: %{term() => non_neg_integer()}
  def command_fold_ordinals(%__MODULE__{command_fold_ordinals: ordinals}), do: ordinals

  @doc "The running `@eventually` pollers."
  @spec active_pollers(t()) :: list()
  def active_pollers(%__MODULE__{active_pollers: pollers}), do: pollers

  @doc "The running resource pollers."
  @spec active_resource_pollers(t()) :: list()
  def active_resource_pollers(%__MODULE__{active_resource_pollers: pollers}), do: pollers

  @doc """
  The microseconds the adapter's `execute/3` took for the most recent
  command, or `nil` when that command never reached the adapter.
  """
  @spec last_execute_us(t()) :: non_neg_integer() | nil
  def last_execute_us(%__MODULE__{last_execute_us: us}), do: us

  @doc """
  The command index an async check failure is attributed to, or `:unset` on
  a state that did not fail that way (DR-025).
  """
  @spec async_failed_index(t()) :: non_neg_integer() | {:setup, non_neg_integer()} | nil | :unset
  def async_failed_index(%__MODULE__{async_failed_index: index}), do: index

  # ============================================================================
  # Updates
  # ============================================================================

  @doc "Replaces the state's log lines with `logs`."
  @spec put_logs(t(), PropertyDamage.Log.logs()) :: t()
  def put_logs(%__MODULE__{} = state, logs), do: %{state | logs: logs}

  @doc """
  Empties the state's lists of running pollers, after the caller stopped
  them.
  """
  @spec clear_pollers(t()) :: t()
  def clear_pollers(%__MODULE__{} = state),
    do: %{state | active_pollers: [], active_resource_pollers: []}

  @doc "Removes the `@eventually` poller whose id is `id` from the running pollers."
  @spec drop_poller(t(), term()) :: t()
  def drop_poller(%__MODULE__{} = state, id),
    do: %{state | active_pollers: Enum.reject(state.active_pollers, &(&1.id == id))}

  @doc """
  The state a finished run left, from the run's `result`: the projections,
  event log, check counters and failures and command fold ordinals the
  result holds, the fold counter past everything finalization folded, and no
  running pollers.
  """
  @spec put_result(t(), map()) :: t()
  def put_result(%__MODULE__{} = state, result) do
    %{
      state
      | projections: result.projections,
        event_log: Enum.reverse(result.event_log),
        check_counters: result.check_counters,
        check_failures: Enum.reverse(result.check_failures),
        command_fold_ordinals: result.command_fold_ordinals,
        fold_counter: next_fold(state.fold_counter, result),
        active_pollers: [],
        active_resource_pollers: []
    }
  end

  # The next fold ordinal after everything finalization folded.
  defp next_fold(counter, result) do
    folded =
      for(%{fold_index: index} when is_integer(index) <- result.event_log, do: index + 1) ++
        Enum.map(Map.values(result.command_fold_ordinals), &(&1 + 1))

    Enum.max([counter | folded])
  end
end
