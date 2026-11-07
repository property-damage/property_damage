defmodule PropertyDamage.Shrinker.Outcome do
  @moduledoc """
  What one shrink candidate did: the answer the shrinker's oracle gives for
  a candidate, and the answer the shrinker gives itself for a candidate it
  never runs.

  The shrinker adopts a candidate only on a `:failed` outcome whose
  `signature` is the original failure's, at the same or an earlier root (see
  `PropertyDamage.Shrinker`). The oracle that `PropertyDamage.Runner.shrink_oracle/2`
  builds makes one from each candidate's run.

    * `status` - `:passed` when the candidate ran without a failure,
      `:failed` when it failed, `:setup_failed` when a target's setup failed
      (never a reproduction, whatever the other failures), and `:invalid`
      when the shrinker rejected the candidate before it ran: the model's
      validation, the realization of its expansions or the replay check.
    * `signature` - the failure's `PropertyDamage.Failure.signature/2`, the
      kind, name and target compared against the original failure; `nil`
      unless `status` is `:failed`.
    * `root` - the index, among the candidate's roots, of the root the
      failure happened at; `nil` when not known or not `:failed`.
    * `reason` - the failure reason, for the reader; `nil` unless `:failed`.
    * `adapter_ms` - the milliseconds the candidate's run spent in the
      adapters' `setup/1` (`:setup`) and `teardown/1` (`:teardown`), summed
      over its targets; `nil` when the oracle does not measure them. The
      shrinker adds them up for its stop event.
  """

  @enforce_keys [:status]
  defstruct [:status, :signature, :root, :reason, :adapter_ms]

  @type status :: :passed | :failed | :setup_failed | :invalid

  @type t :: %__MODULE__{
          status: status(),
          signature: PropertyDamage.Failure.signature() | nil,
          root: non_neg_integer() | nil,
          reason: term(),
          adapter_ms: %{setup: number(), teardown: number()} | nil
        }
end
