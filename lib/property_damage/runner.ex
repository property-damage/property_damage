defmodule PropertyDamage.Runner do
  @moduledoc """
  The one run driver: runs one plan on every target of a run and returns what
  the run did.

  Every run goes through `execute/2`: each generated sequence of a campaign,
  the reproduction of a found failure, the capture of a
  `PropertyDamage.RunTrace` and the trigger isolation of
  `PropertyDamage.Analysis`. So each of them runs the boundary drain after
  every root, and a trace's step events are the events of the run it explains.
  The shrinker's candidate runs do not use it yet.

  A plan is the symbolic sequence of one run (see `t:plan/0`). How the plan
  runs, on which targets and with which options, is a
  `PropertyDamage.Runner.Context`. `execute/2` runs the plan through
  `PropertyDamage.Scheduler.run/1`, the linear lockstep path, so every target
  runs every root and the targets are compared at each root boundary.
  """

  alias PropertyDamage.Runner.Context
  alias PropertyDamage.Scheduler
  alias PropertyDamage.Sequence.Position

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
  def execute(plan, %Context{} = context) do
    context
    |> Map.from_struct()
    |> Map.merge(Map.take(plan, @plan_keys))
    |> Map.to_list()
    |> Scheduler.run()
  end
end
