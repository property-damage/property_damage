defmodule PropertyDamage.Progress.RunResult do
  @moduledoc """
  Terminal result notification for `PropertyDamage.run/1` (DR-022).

  Carries a copy of the authoritative outcome for consumers; the `run/1` return
  value (`{:ok, stats}` | `{:error, report}`) remains the source of truth.

  On a failing run `failure` is the `PropertyDamage.FailureReport`, and `kind`
  and `variant` repeat its report kind and the target the failure happened in
  (`%{index:, name:}`); both are `nil` on a passing run.
  """

  @type t :: %__MODULE__{
          outcome: :ok | :error,
          runs_completed: non_neg_integer() | nil,
          total_commands: non_neg_integer() | nil,
          seed: integer() | nil,
          failure: term() | nil,
          kind: PropertyDamage.FailureReport.kind() | nil,
          variant: PropertyDamage.FailureReport.variant() | nil,
          # Anti-vacuity summary {covered, total} for the terse footer (DR-026),
          # nil when no invariants are declared or on a failing run.
          invariants: {non_neg_integer(), non_neg_integer()} | nil
        }

  @enforce_keys [:outcome]
  defstruct [
    :outcome,
    :runs_completed,
    :total_commands,
    :seed,
    :failure,
    :kind,
    :variant,
    :invariants
  ]
end
