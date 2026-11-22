defmodule PropertyDamage.Corpus.Engine.Next do
  @moduledoc """
  The engine that runs entries through `PropertyDamage.Next.run/1`.

  Each seed gets a fresh `PropertyDamage.Corpus.FireLog`. The entry's adapter
  receives it in its config as `:fire_log`, together with the entry's `:bug`
  switch. The run draws plans of at most the entry's `max_commands` steps,
  and at most `plan_cap` plans, with the entry's `run_opts` as further
  options of `PropertyDamage.Next.run/1`. The result is read from the
  failure:

    * `plans_until_found` is the number of the plan that failed.
    * `shrink_runs` is the number of plans the shrink executed.
    * `shrunk` is the final plan of the shrink, normalized to plain maps.
    * `kept` is the run's kept list: the sites where a `from/2` function
      or a dependent assign returned a StreamData generator.

  With `dependent_stream_data: :raise` in `run_opts`, a run that reaches
  such a site raises `PropertyDamage.Next.DependentStreamDataError`. The
  engine answers it as a run that found nothing, with the site on `kept`.

  `bug_fired?` is read from the final plan's own run. A shrink executes
  candidates after the failure, and an adapter may start systems that run
  no plan, so the most recently started system instance need not be the one
  that ran the final plan. After a failure the engine therefore replays the
  final journal once with a fresh fire log and reads whether the bug fired
  there. That replay is the harness's, not the engine's: it counts neither
  in `shrink_runs`, which is the failure's, nor in `fires`, which counts
  the run's executions across the whole seed. A run that finds nothing has
  no final plan, so its `bug_fired?` is false.
  """

  @behaviour PropertyDamage.Corpus.Engine

  alias PropertyDamage.Corpus.{Entry, FireLog}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.{DependentStreamDataError, Failure, Placeholder, Plan, Step}

  @impl true
  def name, do: "property_damage_next"

  @impl true
  def run(%Entry{} = entry, seed, plan_cap) do
    {:ok, log} = FireLog.start_link()

    try do
      opts = opts(entry, seed, plan_cap, log)
      opts |> Next.run() |> result(log, opts)
    rescue
      error in DependentStreamDataError -> result({:ok, %{kept: [error.site]}}, log, [])
    after
      FireLog.stop(log)
    end
  end

  defp opts(entry, seed, plan_cap, log) do
    [
      model: entry.model,
      adapter: entry.adapter,
      config: %{bug: entry.bug, fire_log: log},
      seed: seed,
      max_steps: entry.max_commands,
      max_plans: plan_cap
    ]
    |> Keyword.merge(entry.run_opts)
  end

  defp result({:error, %Failure{} = failure}, log, opts) do
    %{
      found?: true,
      plans_until_found: failure.plan_number,
      shrink_runs: failure.shrink_runs,
      shrunk: plain_plan(failure.plan),
      bug_fired?: fired_on_replay?(failure, opts),
      fires: FireLog.total(log),
      kept: failure.kept
    }
  end

  defp result({:ok, %{kept: kept}}, log, _opts) do
    %{
      found?: false,
      plans_until_found: nil,
      shrink_runs: 0,
      shrunk: nil,
      bug_fired?: false,
      fires: FireLog.total(log),
      kept: kept
    }
  end

  # Replays the final journal of `failure` with the run's options and a
  # fresh fire log; true when the bug fired in that replay.
  defp fired_on_replay?(failure, opts) do
    {:ok, log} = FireLog.start_link()

    try do
      replay_opts =
        opts
        |> Keyword.take([:model, :adapter, :config, :engine, :dependent_stream_data])
        |> Keyword.update!(:config, &Map.put(&1, :fire_log, log))

      Next.replay(failure.journal, replay_opts)
      FireLog.total(log) > 0
    after
      FireLog.stop(log)
    end
  end

  defp plain_plan(%Plan{steps: steps}),
    do: Enum.map(steps, fn %Step{command: command} -> plain_command(command) end)

  # A command becomes a map of its fields plus its name; a field the system
  # mints (a placeholder in the plan) becomes `:id`.
  defp plain_command(%module{} = command) do
    fields = command |> Map.from_struct() |> Map.new(fn {k, v} -> {k, plain_value(v)} end)
    Map.put(fields, :command, command_name(module))
  end

  defp plain_value(%Placeholder{}), do: :id
  defp plain_value(value), do: value

  defp command_name(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
  end
end
