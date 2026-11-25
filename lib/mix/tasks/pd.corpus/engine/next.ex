defmodule PropertyDamage.Corpus.Engine.Next do
  @moduledoc """
  The engine that runs entries through `PropertyDamage.Next.run/1`.

  Each seed gets a fresh `PropertyDamage.Corpus.FireLog`. The entry's adapter
  receives it in its config as `:fire_log`, together with the entry's `:bug`
  switch. The run draws plans of at most the entry's `max_commands` steps,
  and at most `plan_cap` plans, shrinks with at most 1000 shrink runs, and
  takes the entry's `run_opts` as further options of
  `PropertyDamage.Next.run/1`. The result is read from the
  failure:

    * `plans_until_found` is the number of the plan that failed.
    * `shrink_runs` is the number of plans the shrink executed.
    * `shrunk` is the final plan of the shrink, normalized to plain maps. A
      step that runs a path other than the plain one also has `path:`, the
      path's commands as plain maps.
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

  alias PropertyDamage.Next.{
    DependentStreamDataError,
    Failure,
    Placeholder,
    Plan,
    Report,
    Step
  }

  # The harness's own shrink budget, so a change to the default of
  # `PropertyDamage.Next.run/1` does not move the corpus tables.
  @max_shrink_runs 1_000

  @impl true
  def name, do: "property_damage_next"

  @impl true
  def run(%Entry{} = entry, seed, plan_cap) do
    {:ok, log} = FireLog.start_link()
    level = Logger.get_process_level(self())
    # The run warns once for each kept site, with a timestamp. The result
    # carries the kept list and the task prints it, so this process logs
    # errors only while it runs; the printed table then does not depend on
    # when it ran.
    Logger.put_process_level(self(), :error)

    try do
      opts = opts(entry, seed, plan_cap, log)
      outcome = Next.run(opts)

      if entry.expect,
        do: guardrail_result(entry.expect, outcome, log),
        else: result(outcome, log, opts)
    rescue
      error in DependentStreamDataError ->
        result({:ok, %{kept: [error.site]}}, log, [])

      error ->
        case entry.expect do
          {:raises, module} when is_atom(module) ->
            if is_struct(error, module),
              do: raised_result(error, log),
              else: reraise(error, __STACKTRACE__)

          _ ->
            reraise error, __STACKTRACE__
        end
    after
      restore_level(level)
      FireLog.stop(log)
    end
  end

  defp restore_level(nil), do: Logger.delete_process_level(self())
  defp restore_level(level), do: Logger.put_process_level(self(), level)

  defp opts(entry, seed, plan_cap, log) do
    {model, adapter} = model_and_adapter(entry)

    [
      model: model,
      adapter: adapter,
      config: %{bug: entry.bug, fire_log: log},
      seed: seed,
      max_steps: entry.max_commands,
      max_plans: plan_cap,
      max_shrink_runs: @max_shrink_runs
    ]
    |> Keyword.merge(entry.run_opts)
  end

  # With the bug off, an entry that names a `control` runs the control's
  # model and adapter, a corrected pair of the ones the bug-on run uses.
  defp model_and_adapter(%Entry{bug: nil, control: control} = entry) when is_list(control),
    do: {Keyword.get(control, :model, entry.model), Keyword.get(control, :adapter, entry.adapter)}

  defp model_and_adapter(entry), do: {entry.model, entry.adapter}

  # An entry with `expect` is a guardrail entry: the run is judged by the
  # error it raises or the line its report holds, not by a failing plan.
  defp raised_result(error, log) do
    guardrail(true, Exception.message(error), [], log)
  end

  defp guardrail_result({:report, text}, outcome, log) do
    case report_of(outcome) do
      nil ->
        guardrail(false, nil, [], log)

      %Report{} = report ->
        line = report |> Report.format() |> String.split("\n") |> Enum.find(&(&1 =~ text))
        line = line && String.trim(line)
        guardrail(line != nil, line, report.kept, log)
    end
  end

  defp guardrail_result({:raises, _module}, outcome, log),
    do: guardrail(false, nil, kept_of(outcome), log)

  defp report_of({:ok, %Report{} = report}), do: report
  defp report_of({:error, %Failure{report: %Report{} = report}}), do: report
  defp report_of(_outcome), do: nil

  defp kept_of(outcome), do: if(report = report_of(outcome), do: report.kept, else: [])

  defp guardrail(found?, line, kept, log) do
    %{
      found?: found?,
      plans_until_found: nil,
      shrink_runs: 0,
      shrunk: nil,
      bug_fired?: found?,
      fires: FireLog.total(log),
      kept: kept,
      line: line
    }
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
    do: Enum.map(steps, &plain_step/1)

  # A step becomes its command's map plus the step's truthy assigns, so a
  # fault a layer set (such as a lost response) is part of the plan.
  # A step in a lane also says which one, so a plan shows the steps that overlap.
  # A step that runs a path other than the plain one lists the path's
  # commands as plain maps under `:path`.
  defp plain_step(%Step{key: step_key, command: command, assigns: assigns, path: path}) do
    truthy = for {key, value} <- assigns, value, into: %{}, do: {key, plain_value(value)}
    plain = Map.merge(plain_command(command), truthy)

    plain =
      case step_key do
        {lane, _slot} when lane > 0 -> Map.put(plain, :lane, lane)
        _prefix -> plain
      end

    case path do
      {index, commands} when index > 0 ->
        Map.put(plain, :path, Enum.map(commands, &plain_command/1))

      _plain_path ->
        plain
    end
  end

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
