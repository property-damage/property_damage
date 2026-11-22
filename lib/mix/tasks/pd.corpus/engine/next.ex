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

  The shrink executes its final plan last, so with an adapter that starts
  one system per execution the most recently started system instance is
  the one that ran the final plan, which is what `bug_fired?` reads.
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
      entry |> execute(seed, plan_cap, log) |> result(log)
    rescue
      error in DependentStreamDataError -> result({:ok, %{kept: [error.site]}}, log)
    after
      FireLog.stop(log)
    end
  end

  defp execute(entry, seed, plan_cap, log) do
    [
      model: entry.model,
      adapter: entry.adapter,
      config: %{bug: entry.bug, fire_log: log},
      seed: seed,
      max_steps: entry.max_commands,
      max_plans: plan_cap
    ]
    |> Keyword.merge(entry.run_opts)
    |> Next.run()
  end

  defp result({:ok, %{kept: kept}}, log) do
    %{
      found?: false,
      plans_until_found: nil,
      shrink_runs: 0,
      shrunk: nil,
      bug_fired?: FireLog.fired_in_last_instance?(log),
      fires: FireLog.total(log),
      kept: kept
    }
  end

  defp result({:error, %Failure{} = failure}, log) do
    %{
      found?: true,
      plans_until_found: failure.plan_number,
      shrink_runs: failure.shrink_runs,
      shrunk: plain_plan(failure.plan),
      bug_fired?: FireLog.fired_in_last_instance?(log),
      fires: FireLog.total(log),
      kept: failure.kept
    }
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
