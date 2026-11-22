defmodule PropertyDamage.Corpus.Engine.Run do
  @moduledoc """
  The engine that runs entries through `PropertyDamage.run/1`.

  Each seed gets a fresh `PropertyDamage.Corpus.FireLog`. The entry's adapter
  receives it in its target config as `:fire_log`, together with the entry's
  `:bug` switch, and hands both to the system. The result is read from the
  failure report:

    * `plans_until_found` is the report's run number, the plan that failed.
    * `shrink_runs` is the number of shrink candidates the shrinker ran.
    * `shrunk` is the report's shrunk plan, normalized to plain maps.
  """

  @behaviour PropertyDamage.Corpus.Engine

  alias PropertyDamage.Corpus.{Entry, FireLog}
  alias PropertyDamage.{FailureReport, Placeholder, Sequence}

  @impl true
  def name, do: "property_damage_run"

  @impl true
  def run(%Entry{} = entry, seed, plan_cap) do
    {:ok, log} = FireLog.start_link()

    try do
      entry |> execute(seed, plan_cap, log) |> result(log)
    after
      FireLog.stop(log)
    end
  end

  defp execute(entry, seed, plan_cap, log) do
    PropertyDamage.run(
      model: entry.model,
      targets: [{entry.adapter, config: %{bug: entry.bug, fire_log: log}}],
      seed: seed,
      max_commands: entry.max_commands,
      max_runs: plan_cap,
      verbose: false
    )
  end

  defp result({:ok, _stats}, log) do
    %{
      found?: false,
      plans_until_found: nil,
      shrink_runs: 0,
      shrunk: nil,
      bug_fired?: FireLog.fired_in_last_instance?(log),
      fires: FireLog.total(log),
      kept: []
    }
  end

  defp result({:error, %FailureReport{} = report}, log) do
    %{
      found?: true,
      plans_until_found: FailureReport.run_number(report),
      shrink_runs: report.shrink_iterations,
      shrunk: report |> FailureReport.shrunk_sequence() |> plain_plan(),
      bug_fired?: FireLog.fired_in_last_instance?(log),
      fires: FireLog.total(log),
      kept: []
    }
  end

  defp plain_plan(%Sequence{} = plan),
    do: plan |> Sequence.to_list() |> Enum.map(&plain_command/1)

  defp plain_plan(nil), do: nil

  # A command becomes a map of its fields plus its name; a field the system
  # minted (a placeholder) becomes `:id`.
  defp plain_command(%module{} = command) do
    fields = command |> Map.from_struct() |> Map.new(fn {k, v} -> {k, plain_value(v)} end)
    Map.put(fields, :command, command_name(module))
  end

  defp plain_value(value) do
    if Placeholder.placeholder?(value), do: :id, else: value
  end

  defp command_name(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
  end
end
