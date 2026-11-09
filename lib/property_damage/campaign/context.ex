defmodule PropertyDamage.Campaign.Context do
  @moduledoc """
  Everything one campaign holds for the whole of a run: the targets it runs
  on, the seeds it draws from, the options it was given and the callbacks that
  announce its progress and its failures.

  The campaign loop, the failure path (`PropertyDamage.Reproduction`) and the
  report builder (`PropertyDamage.ReportBuilder`) all read this struct. The
  re-shrink of an existing report builds the same struct and leaves the fields
  that only a campaign uses at their defaults.

  `model`, `targets` and `target` are required. The rest default to the value
  a field holds when the option behind it is off.

  ## What runs

    * `model` - the model module.
    * `targets` - the targets that execute, in order. The first is the
      reference. A `:reference` target that runs alone executes as `:random`.
    * `all_targets` - every target of `targets:`, whichever of them `only:`
      runs. Each target's choices are computed on this list.
    * `target_entries` - the entries of the targets that run, as a report
      records them.
    * `target` - the reference target.

  ## How far and from which seed

    * `max_commands`, `max_runs` - the size of each sequence and the number of
      runs.
    * `first_run` - the 0-based run the loop starts at. Non-zero under
      `only: [run: n]`.
    * `seed` - the campaign seed. Run 0 uses it as is.
    * `run_nonce` - the nonce that seeds the values each run mints for itself.
      Every target of a run shares it.
    * `replay` - under `only: [replay: path]`, the artifact term, its path and
      the sequence and choices it records; `nil` otherwise.
    * `generator` - the sequence generator of the model. The campaign sets it
      when it starts.

  ## When a run fails

    * `shrink` - whether a failure is shrunk.
    * `shrinker_config` - the `PropertyDamage.Shrinker.Config` of that shrink.
    * `on_failure` - the callback that receives the failure report, or `nil`.
    * `replay_dir` - where a failure's replay artifact goes, or `false` for
      nowhere.
    * `report_html` - the directory of the failure report's HTML page, or `nil`.
    * `measured_metrics` - the latency metrics measured up to a failed run. The
      campaign sets it when a run fails.

  ## Run options

  Each of these is the option of the same name on the public `run/1`, as
  validated, unless noted.

    * `concurrency`, `compare`, `check_mode`, `external_markers`.
    * `stutter` - the `stutter:` options as given. `stutter_config/1` parses
      them into a `PropertyDamage.Stutter.Config` (`nil` without stutter).
    * `keep_attempts` - how many of a step's last settle or stutter attempts
      keep their log lines (`log: [keep_attempts: n]`).
    * `log_filter` - the tag filter of `log:`.
    * `setup_log` - the `setup_log:` option.
    * `coverage` - whether the command, transition and state tracker runs.
    * `latency` - the `latency:` option as the caller wrote it, which the
      reproduction command prints, and `latency_budget` - the validated
      option (`false` or the budget). `measure_latency?/1` tells whether
      target timings are recorded.

  ## Progress and seams

    * `reporter` - the progress reporter that every progress update
      goes to. The campaign loop needs one; a reporter built with no
      consumers reports nothing.
    * `run_once` - the step of one run, `(ctx, run_number, acc -> {:pass, acc}
      | {:error, found})`. `nil` means the campaign's own, which generates the
      sequence and runs it on every target. A test sets it to drive the loop
      without a model or a target.
  """

  alias PropertyDamage.Log.Cap
  alias PropertyDamage.Stutter

  @enforce_keys [:model, :targets, :target]
  defstruct [
    :model,
    :targets,
    :target,
    :all_targets,
    :target_entries,
    :max_commands,
    :max_runs,
    :seed,
    :run_nonce,
    :replay,
    :generator,
    :shrink,
    :shrinker_config,
    :on_failure,
    :replay_dir,
    :report_html,
    :measured_metrics,
    :stutter,
    :log_filter,
    :reporter,
    :run_once,
    first_run: 0,
    concurrency: :serial,
    compare: [],
    check_mode: :halt,
    external_markers: [],
    keep_attempts: Cap.default_keep_attempts(),
    setup_log: [],
    coverage: false,
    latency: false,
    latency_budget: false
  ]

  @type t :: %__MODULE__{
          model: module(),
          targets: [PropertyDamage.Target.t()],
          target: PropertyDamage.Target.t(),
          all_targets: [PropertyDamage.Target.t()] | nil,
          target_entries: [{module(), keyword()}] | nil,
          max_commands: pos_integer() | nil,
          max_runs: pos_integer() | nil,
          seed: integer() | nil,
          run_nonce: integer() | nil,
          replay: map() | nil,
          generator: StreamData.t(term()) | nil,
          shrink: boolean() | nil,
          shrinker_config: PropertyDamage.Shrinker.Config.t() | nil,
          on_failure: (PropertyDamage.FailureReport.t() -> term()) | nil,
          replay_dir: Path.t() | false | nil,
          report_html: Path.t() | nil,
          measured_metrics: map() | nil,
          stutter: keyword() | nil,
          log_filter: PropertyDamage.Log.Filter.t() | nil,
          reporter: struct() | nil,
          run_once: (t(), non_neg_integer(), map() -> {:pass, map()} | {:error, term()}) | nil,
          first_run: non_neg_integer(),
          concurrency: :serial | :parallel,
          compare: keyword(),
          check_mode: :disabled | :halt | :record | :log,
          external_markers: [atom()],
          keep_attempts: non_neg_integer(),
          setup_log: keyword(),
          coverage: boolean(),
          latency: false | keyword(),
          latency_budget: false | keyword()
        }

  @doc """
  The `PropertyDamage.Stutter.Config` of the context's `stutter` options, or
  `nil` when the context has none.
  """
  @spec stutter_config(t()) :: Stutter.Config.t() | nil
  def stutter_config(%__MODULE__{stutter: stutter}), do: Stutter.parse_config(stutter)

  @doc """
  Whether the run records each target's per-command latency, which it does
  under `latency:`.
  """
  @spec measure_latency?(t()) :: boolean()
  def measure_latency?(%__MODULE__{latency_budget: budget}), do: budget != false
end
