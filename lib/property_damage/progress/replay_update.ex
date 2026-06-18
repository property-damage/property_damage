defmodule PropertyDamage.Progress.ReplayUpdate do
  @moduledoc """
  Progress for the seed-library replay phase of `PropertyDamage.run/1` (DR-023).

  Classified under the `:test_run` operation alongside `RunUpdate`/`RunResult`,
  this payload reports the pre-exploration replay of previously-failing seeds.

  ## Phases

  - `:start` — emitted once when a non-empty library begins replaying; carries
    `file`, `seed_count`, and the prune threshold `prune_after`.
  - `:seed` — emitted per replayed seed with its `seed` and `outcome`
    (`:pass`, `:fail`, or `:prune` when a pass reaches the prune threshold).
  - `:summary` — emitted once after the replay pass with `replayed`, `passed`,
    `pruned`, and `still_failing` counts, and `halted?` (whether exploration was
    skipped because seeds still fail).
  """

  @type phase :: :start | :seed | :summary
  @type outcome :: :pass | :fail | :prune

  @type t :: %__MODULE__{
          phase: phase(),
          file: String.t() | nil,
          seed_count: non_neg_integer() | nil,
          prune_after: pos_integer() | nil,
          seed: integer() | nil,
          outcome: outcome() | nil,
          replayed: non_neg_integer() | nil,
          passed: non_neg_integer() | nil,
          pruned: non_neg_integer() | nil,
          still_failing: non_neg_integer() | nil,
          halted?: boolean() | nil
        }

  @enforce_keys [:phase]
  defstruct [
    :phase,
    :file,
    :seed_count,
    :prune_after,
    :seed,
    :outcome,
    :replayed,
    :passed,
    :pruned,
    :still_failing,
    :halted?
  ]
end
