defmodule PropertyDamage.Runner do
  @moduledoc """
  The one run driver: runs one plan on every target of a run and returns what
  the run did.

  Every run goes through `execute/2`: each generated sequence of a campaign,
  the reproduction of a found failure, the capture of a
  `PropertyDamage.RunTrace` and the trigger isolation of
  `PropertyDamage.Analysis`, and each candidate the shrinker tries, through
  the oracle `shrink_oracle/2` builds. So each of them runs the boundary drain
  after every root, and a trace's step events are the events of the run it
  explains.

  A plan is the symbolic sequence of one run (see `t:plan/0`). How the plan
  runs, on which targets and with which options, is a
  `PropertyDamage.Runner.Context`. `execute/2` runs the plan through
  `PropertyDamage.Scheduler.run/1`, the linear lockstep path, so every target
  runs every root and the targets are compared at each root boundary.
  """

  alias PropertyDamage.{Failure, Scheduler, Stutter}
  alias PropertyDamage.Runner.Context
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Shrinker.Outcome

  @plan_keys [:commands, :variants, :setup_commands, :teardown_commands, :placeholder_registry]

  @typedoc """
  The symbolic sequence of one run:

    * `commands` - the roots, in order.
    * `variants` - what each target executes for the roots, in target order:
      per target `%{roots: roots, registry: registry}`, as the `:variants`
      option of `PropertyDamage.Scheduler.run/1` describes it; `nil` when
      every target runs every root as itself.
    * `setup_commands`, `teardown_commands` - the commands every target runs
      before the first root and after the final boundary.
    * `placeholder_registry` - the registry the commands' placeholders
      resolve against (DR-021), opaque to callers.
  """
  @type plan :: %{
          commands: [struct()],
          variants: [%{roots: [[{struct(), Position.t() | nil}]], registry: term()}] | nil,
          setup_commands: [struct()],
          teardown_commands: [struct()],
          placeholder_registry: term() | nil
        }

  @doc """
  Runs `plan` on every target of `context` and returns the scheduler's
  outcome, `{:ok, run}` (see `t:PropertyDamage.Scheduler.run/0`).
  """
  @spec execute(plan(), Context.t()) :: {:ok, Scheduler.run()}
  def execute(_plan, %Context{seed: seed}) when not is_integer(seed) do
    raise ArgumentError,
          "`PropertyDamage.Runner.Context` needs an integer `seed`, got: #{inspect(seed)}"
  end

  def execute(plan, %Context{} = context) do
    context
    |> Map.from_struct()
    |> Map.merge(Map.take(plan, @plan_keys))
    |> Map.to_list()
    |> Scheduler.run()
  end

  @doc """
  The oracle `PropertyDamage.Shrinker.shrink/2` runs its candidates through:
  a function `(plan, mint_epoch) -> %PropertyDamage.Shrinker.Outcome{}` that
  runs the plan with `execute/2` on every target of `context`, as a fresh
  execution with the mint epoch the shrinker drew, and says what it did.

  `context` describes how every candidate runs. Its `seed` is the failing
  run's effective seed and its `run_number` is `0`, so every candidate runs
  as run 0 of that seed and the per-target RNG and the stutter decisions
  match the original run. `signature` is the original failure's
  `PropertyDamage.Failure.signature/2`, or `nil` when it is not known. A
  stutter failure (`:idempotency_violation`, `:stutter_execution_failed`)
  reproduces only when the command at fault stutters, and its index moves as
  the shrinker removes earlier roots. So for such a signature every
  candidate runs with the context's stutter configuration forced on, at
  probability 1.0; for any other signature, or none, without stutter.

  A run with no failure is `:passed`. A run in which any target's setup
  failed is `:setup_failed`, whatever its other failures. Any other failing
  run is `:failed`, with the signature, root and reason of its primary
  failure.
  """
  @spec shrink_oracle(Context.t(), Failure.signature() | nil) ::
          (plan(), pos_integer() -> Outcome.t())
  def shrink_oracle(%Context{} = context, signature) do
    stutter_config = shrink_stutter_config(signature, context.stutter_config)
    context = %{context | stutter_config: stutter_config}

    fn plan, mint_epoch ->
      {:ok, run} = execute(plan, %{context | mint_epoch: mint_epoch})
      %{outcome(run) | adapter_ms: adapter_ms(run)}
    end
  end

  defp shrink_stutter_config({kind, _name, _variant_index}, %Stutter.Config{} = config)
       when kind in [:idempotency_violation, :stutter_execution_failed],
       do: %{config | probability: 1.0, enabled: true}

  defp shrink_stutter_config(_signature, _config), do: nil

  # The milliseconds the run's targets spent in the adapters' setup/1 and
  # teardown/1. Each target's result holds the timers its variant filled in;
  # a target whose setup failed left no result, so the run lists its timers
  # apart.
  defp adapter_ms(%{results: results, setup_timers: setup_timers}) do
    timers = for(%{adapter_timers: timers} <- results, do: timers) ++ setup_timers

    %{
      setup: Enum.sum(for t <- timers, do: :atomics.get(t, 1)) / 1000,
      teardown: Enum.sum(for t <- timers, do: :atomics.get(t, 2)) / 1000
    }
  end

  defp outcome(%{failure: nil}), do: %Outcome{status: :passed}

  defp outcome(%{failure: failure, other_failures: others}) do
    if Enum.any?([failure | others], &(&1.report_kind == :setup_failed)) do
      %Outcome{status: :setup_failed}
    else
      %{reason: reason, variant: %{index: index}, root: root} = failure

      %Outcome{
        status: :failed,
        signature: Failure.signature(reason, index),
        root: root,
        reason: reason
      }
    end
  end
end
