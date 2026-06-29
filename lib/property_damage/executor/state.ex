defmodule PropertyDamage.Executor.State do
  @moduledoc """
  Typed run-state for `PropertyDamage.Executor` (DR-029).

  Built once per run by `Executor.build_initial_state/7` (and via `init_state/2`
  for the `PropertyDamage.Replay` stepping shell), then threaded through the
  per-command engine, the branching fork/merge, and the finalize chain.

  This replaces the former untyped flat map. With `Executor.put_state/2` rewritten
  to `struct!/2` and the in-loop updates using struct-update syntax, a write to an
  **undeclared** field now raises instead of silently producing a corrupt
  struct-shaped map (`Map.merge/2` onto a struct does not raise). The two fields
  that previously existed only as "ghosts" (entering solely via `Map.put` writes
  and `Map.get(state, k, default)` reads, never initialized in
  `build_initial_state/7`) are declared here with explicit defaults:
  `:active_faults` and `:async_halt`.

  ## Fields

  Run identity / configuration (provided at construction):

    * `:model` - the model module
    * `:event_queue` - `EventQueue` pid for injector/poller events (or `nil`)
    * `:assertion_mode` - `:halt | :record | :log | :disabled`
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
    * `:step_count` - number of commands executed
    * `:assertion_counters` - `%{step:, command:, event:, ...}` firing counts
    * `:assertion_failures` - accumulated `:record`-mode failures (newest-first)
    * `:branch_id` - current branch id during branching (`nil` on the linear path)
    * `:active_pollers` - running `@poll_state` pollers
    * `:active_resource_pollers` - running resource pollers
    * `:active_faults` - `%{{nemesis_module, index} => fault}` (ghost field)
    * `:async_halt` - `{name, reason, command_index}` set when a DR-025 async
      `every:` assertion trips during a `@poll_state` await drain (ghost field)
  """

  @enforce_keys [
    :model,
    :event_queue,
    :assertion_mode,
    :stutter_config,
    :mock_registry,
    :external_markers,
    :command_specs,
    :placeholder_registry
  ]
  defstruct [
    :model,
    :event_queue,
    :assertion_mode,
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
    step_count: 0,
    assertion_counters: %{step: 0, command: 0, event: 0},
    assertion_failures: [],
    branch_id: nil,
    active_pollers: [],
    active_resource_pollers: [],
    active_faults: %{},
    async_halt: nil
  ]

  @type t :: %__MODULE__{
          model: module(),
          event_queue: pid() | nil,
          assertion_mode: atom(),
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
          step_count: non_neg_integer(),
          assertion_counters: map(),
          assertion_failures: list(),
          branch_id: term(),
          active_pollers: list(),
          active_resource_pollers: list(),
          active_faults: map(),
          async_halt: term()
        }
end
