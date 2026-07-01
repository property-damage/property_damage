defmodule PropertyDamage.FailureReport.Step do
  @moduledoc """
  One command in a failed run, paired with everything observed about it.

  A `Step` is the first-class value callers pattern-match instead of re-walking
  `shrunk_sequence` / `event_log` / `failed_at_index` to reconstruct "what
  happened at command N". `PropertyDamage.FailureReport.steps/1` produces the
  full timeline; `events_at/2` and `failure_step/1` are sugar over it.

  ## Fields

  - `position` — the command's canonical `Sequence.Position` (section + offset),
    unambiguous across parallel branches.
  - `flattened_index` — the command's `Sequence.to_list/1` reading-order ordinal.
    This is what labels, exporters, and diff alignment key on. It is the *derived*
    view of the location; `position` is authoritative. For branch commands it
    differs from the executor command index.
  - `command` — the command struct.
  - `events` — the events observed for this command, in log order. These are the
    event log entries whose `(command_index, branch_id)` resolves to this step's
    `position` (command-produced events only; injector/telemetry events, which
    carry no command index, belong to no step).
  - `label` — the command's human-readable label (`command_labels` for this
    `flattened_index`), or `nil` if the model produced none.
  - `failed?` — `true` for the single step where the failure was localized, and
    `false` everywhere else. At most one step in a timeline is `failed?`; a
    non-localized failure (teardown / whole-run / linearization) has none.

  Structural only: a `Step` carries no projection state. The authoritative state
  snapshots stay on the `FailureReport` (`state_before_failure`,
  `state_at_failure`).
  """

  alias PropertyDamage.Sequence

  @type t :: %__MODULE__{
          position: Sequence.Position.t(),
          flattened_index: non_neg_integer(),
          command: struct(),
          events: [struct()],
          label: String.t() | nil,
          failed?: boolean()
        }

  @enforce_keys [:position, :flattened_index, :command, :events, :label, :failed?]
  defstruct [:position, :flattened_index, :command, :events, :label, :failed?]
end
