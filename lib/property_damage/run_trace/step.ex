defmodule PropertyDamage.RunTrace.Step do
  @moduledoc """
  One command in a run, paired with everything observed about it.

  A `Step` is the first-class value callers pattern-match instead of re-walking
  a run's `plan` / `event_log` to reconstruct "what happened at command N".
  `PropertyDamage.RunTrace.steps/1` produces the full timeline;
  `event_entries_at/2` is sugar over it, and `FailureReport` overlays its
  failure-localization on top of the same steps.

  A `Step` describes any run, passing or failing (DR-033): `failed?` is simply
  never true on a passing trace, and only a `FailureReport` (which knows the
  localized `failed_at_index`) ever marks a step failed.

  ## Fields

  - `position` — the command's canonical `Sequence.Position` (section + offset),
    unambiguous across parallel branches.
  - `flattened_index` — the command's `Sequence.to_list/1` reading-order ordinal.
    This is what labels, exporters, and diff alignment key on. It is the *derived*
    view of the location; `position` is authoritative. For branch commands it
    differs from the executor command index.
  - `command` — the command struct as it appears in the *plan* (symbolic: it may
    still carry unresolved `%Placeholder{}` / mint markers). This is what
    renderers and exporters read.
  - `executed_command` — the concrete command actually sent to the adapter for
    this position (post placeholder/mint resolution), or `nil` when not captured
    (e.g. a synthesized or hand-built trace). Added by DR-033; `command` keeps
    its symbolic meaning so existing renderers are unaffected.
  - `entries` — the `EventLog.Entry` structs observed for this command, in log
    order: the log entries whose `(command_index, branch_id)` resolves to this
    step's `position`. Everything *attributed* to the command by its index,
    including its own output plus any mock / nemesis / stutter events recorded
    against it. Full entries (not bare events) are kept so per-event provenance
    survives: each entry carries its `source`
    (`:command` / `:nemesis` / `:mock` / `:stutter` / `:resource_poller`) and
    `branch_id`. The bare event struct is `entry.event`. Injector / telemetry
    events carry no command index and belong to no step (see
    `PropertyDamage.RunTrace.async_entries/1`).
  - `label` — the command's human-readable label (`command_labels` for this
    `flattened_index`), or `nil` if the model produced none.
  - `failed?` — `true` for the single step where a failure was localized, and
    `false` everywhere else. At most one step in a timeline is `failed?`; a
    passing run, or a non-localized failure (teardown / whole-run /
    linearization), has none.

  Structural only: a `Step` carries no projection state. On a `FailureReport`
  the authoritative state snapshots stay on the report (`state_before_failure`,
  `state_at_failure`).
  """

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Sequence

  @type t :: %__MODULE__{
          position: Sequence.Position.t(),
          flattened_index: non_neg_integer(),
          command: struct(),
          executed_command: struct() | nil,
          entries: [Entry.t()],
          label: String.t() | nil,
          failed?: boolean()
        }

  @enforce_keys [:position, :flattened_index, :command, :entries, :label, :failed?]
  defstruct [
    :position,
    :flattened_index,
    :command,
    :executed_command,
    :entries,
    :label,
    :failed?
  ]
end
