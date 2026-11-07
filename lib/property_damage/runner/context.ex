defmodule PropertyDamage.Runner.Context do
  @moduledoc """
  How `PropertyDamage.Runner.execute/2` runs a plan: the model, the targets,
  and the run options the lockstep scheduler takes.

  `model` and `targets` are required. Every other field is the
  `PropertyDamage.Scheduler.run/1` option of the same name, and defaults to
  the value `PropertyDamage.run/1` passes or the scheduler assumes:

    * `seed` - the campaign seed. Default `nil`; the scheduler requires a
      seed, so a context without one fails when executed.
    * `run_number` - the 0-based run of the campaign. Default `0`, the first
      run.
    * `run_seed` - the run's effective seed, when `seed` and `run_number` do
      not derive it, as in the reproduction of a found run. Default `nil`:
      derived from them.
    * `run_nonce` - the run nonce every target shares. Default `nil`.
    * `mint_epoch` - the mint epoch of client-minted values (DR-034).
      Default `0`, the epoch of a campaign run.
    * `concurrency` - `:serial` or `:parallel`. Default `:serial`.
    * `compare` - `[converge_within: ms]`, the convergence bound of each
      boundary comparison. Default `[]`, which the scheduler reads as
      `[converge_within: 5_000]`.
    * `measure_latency` - record each target's per-command latency.
      Default `false`.
    * `stutter_config` - a `PropertyDamage.Stutter.Config`, or `nil` for no
      stutter. Default `nil`.
    * `keep_attempts` - how many of a step's last settle or stutter attempts
      keep their log lines besides the first attempt's (DR-054). Default `3`,
      the log cap's default.
    * `check_mode` - how a failing check is handled, as `check_mode:` on
      `PropertyDamage.run/1`. Default `:halt`.
  """

  alias PropertyDamage.Log.Cap

  @enforce_keys [:model, :targets]
  defstruct [
    :model,
    :targets,
    :seed,
    :run_seed,
    :run_nonce,
    :stutter_config,
    run_number: 0,
    mint_epoch: 0,
    concurrency: :serial,
    compare: [],
    measure_latency: false,
    keep_attempts: Cap.default_keep_attempts(),
    check_mode: :halt
  ]

  @type t :: %__MODULE__{
          model: module(),
          targets: [PropertyDamage.Target.t()],
          seed: integer() | nil,
          run_number: non_neg_integer(),
          run_seed: integer() | nil,
          run_nonce: integer() | nil,
          mint_epoch: non_neg_integer(),
          concurrency: :serial | :parallel,
          compare: keyword(),
          measure_latency: boolean(),
          stutter_config: PropertyDamage.Stutter.Config.t() | nil,
          keep_attempts: non_neg_integer(),
          check_mode: :disabled | :halt | :record | :log
        }
end
