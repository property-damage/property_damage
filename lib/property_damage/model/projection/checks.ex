defmodule PropertyDamage.Model.Projection.Checks do
  @moduledoc """
  Reads and runs the checks a projection declares.

  `list/1` is the one way to read a projection's check list. The functions that
  evaluate checks (`step_checks/4`, `phase_checks/2`, `eventually_checks/1`)
  filter that list by `PropertyDamage.Model.Projection.Check` kind.
  """

  alias PropertyDamage.Model.Projection
  alias PropertyDamage.Model.Projection.Check
  alias PropertyDamage.ModuleCheck
  alias PropertyDamage.Telemetry
  alias PropertyDamage.Verdict

  @doc """
  The checks `projection` declares, in declaration order.

  Returns `[]` for a module that does not use `PropertyDamage.Model.Projection`.
  An entry from a hand-written check list is returned as written.
  """
  @spec list(module()) :: [Check.t() | map()]
  def list(projection) do
    if ModuleCheck.exports?(projection, :__checks__, 0) do
      projection.__checks__()
    else
      []
    end
  end

  @doc """
  True when `projection` has a check list, even an empty one.

  A module has one when it uses `PropertyDamage.Model.Projection`. The state
  projection of a model may be a plain module without it.
  """
  @spec declared?(module()) :: boolean()
  def declared?(projection), do: ModuleCheck.exports?(projection, :__checks__, 0)

  @doc """
  The `:phase` checks of `projection` that run at the lifecycle boundary `phase`
  (`:startup` or `:teardown`).

  Raises `ArgumentError` for a hand-written entry without a `:type` key.
  """
  @spec phase_checks(module(), :startup | :teardown) :: [Check.t()]
  def phase_checks(projection, phase) do
    Enum.filter(list(projection), fn check ->
      kind!(projection, check) == :phase and check.trigger.phase == phase
    end)
  end

  @doc """
  The `:eventually` checks of `projection`.
  """
  @spec eventually_checks(module()) :: [Check.t()]
  def eventually_checks(projection) do
    Enum.filter(list(projection), &(kind!(projection, &1) == :eventually))
  end

  @doc """
  Runs the `:step` checks of `projection` that fire for the step in `step_ctx`.

  `step_ctx` carries `:step_type`, `:module` and `:command_or_event`, plus
  optional `:sampling` (default `true`; a step that does not sample skips the
  `every: N` checks) and `:telemetry`. `counters` is the run's check counters.

  Returns `{:ok, counters}` with the firings recorded, or
  `{:error, check_name, {exception, stacktrace}, counters}` for the first check
  that fails.
  """
  @spec step_checks(module(), term(), map(), map()) ::
          {:ok, map()} | {:error, atom(), {term(), list()}, map()}
  def step_checks(projection, projection_state, step_ctx, counters) do
    # A step that does not sample (a setup command's) skips the `every: N`
    # triggers: they read counters it did not advance.
    sampling = Map.get(step_ctx, :sampling, true)
    telemetry = Map.get(step_ctx, :telemetry)

    checks =
      projection
      |> list()
      |> Enum.filter(fn check ->
        kind!(projection, check) == :step and
          (sampling or not match?(%{type: :every_n}, check.trigger))
      end)

    Enum.reduce_while(checks, {:ok, counters}, fn check, {:ok, acc_counters} ->
      if Projection.should_run?(
           check.trigger,
           step_ctx.step_type,
           step_ctx.module,
           acc_counters
         ) do
        # The check runs: record the firing (DR-026) before invoking it, so
        # a failing check still counts as exercised. This single site covers
        # both the synchronous command/event path and the asynchronous
        # observation path (DR-025).
        fired = record_fire(acc_counters, projection, check.name)

        # The check's return is its verdict (DR-052); a raise is captured
        # with its stacktrace.
        case Telemetry.check_span(telemetry, projection, check.name, fn ->
               projection
               |> apply(check.function_name, [projection_state, step_ctx.command_or_event])
               |> Verdict.check(check.name)
             end) do
          :ok -> {:cont, {:ok, fired}}
          {:failed, e, stacktrace} -> {:halt, {:error, check.name, {e, stacktrace}, fired}}
        end
      else
        {:cont, {:ok, acc_counters}}
      end
    end)
  end

  @doc """
  Records one firing of a check (DR-026).

  Per-check fire counts are colocated as `{:fired, projection, name}` keys inside
  the check counters map: inert to `PropertyDamage.Model.Projection.should_run?/4`,
  which does only point lookups and never iterates.
  """
  @spec record_fire(map(), module(), atom()) :: map()
  def record_fire(counters, projection, name) do
    Map.update(counters, {:fired, projection, name}, 1, &(&1 + 1))
  end

  # A hand-written check-list entry without `:type` is a model fault, so
  # it raises with the projection and the entry instead of skipping the entry.
  defp kind!(_projection, %Check{kind: kind}), do: kind
  defp kind!(_projection, %{type: _} = entry), do: Check.kind_for(entry)

  defp kind!(projection, entry) do
    raise ArgumentError,
          "#{inspect(projection)}.__checks__/0 returned an entry without a :type key " <>
            "(expected :synchronous or :eventually): #{inspect(entry)}"
  end
end
