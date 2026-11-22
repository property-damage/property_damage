defmodule PropertyDamage.Next.Checks do
  @moduledoc false
  # The checks an execution evaluates: the `@check` functions of the model's
  # check projections, each projection folding the real events the adapter
  # returns.
  #
  # This engine runs two schedules: `every: N`, sampled over the commands and
  # events executed so far (a command counts one, and so does each of its
  # events, as in today's engine), and `every: Module`, after each command or
  # event of that module. Loading a model whose check projections declare any
  # other form raises, so no check is skipped without a word.
  #
  # After a step, every projection first folds all of the step's events; then
  # the checks the command triggers run, then those each event triggers, in
  # event order. A check fails by returning `nil` or `false`, by returning
  # `{:fail, message}`, or by raising (`PropertyDamage.fail!/2` raises); the
  # verdict is read by today's check runner.

  alias PropertyDamage.Model.Projection.Checks, as: ProjectionChecks

  @type t :: %{projections: [module()], states: map(), counters: map()}

  @doc """
  The check projections of `model`, after making sure every check they
  declare has a schedule this engine runs. Raises `ArgumentError` otherwise.
  """
  @spec load!(module()) :: [module()]
  def load!(model) do
    projections = model.check_projections()

    unless is_list(projections) and Enum.all?(projections, &is_atom/1) do
      raise ArgumentError,
            "#{inspect(model)}.check_projections/0 must return a list of projection " <>
              "modules, got: #{inspect(projections)}"
    end

    Enum.each(projections, &supported!/1)
    projections
  end

  @doc "The state of a fresh execution: every projection at `init/0`."
  @spec init([module()]) :: t()
  def init(projections) do
    %{
      projections: projections,
      states: Map.new(projections, &{&1, &1.init()}),
      counters: %{step: 0, command: 0, event: 0}
    }
  end

  @doc """
  Folds one step's real events into every projection and runs the checks
  the command and its events trigger. Returns the new state, or the first
  failing check as `{:check, name, message}`.
  """
  @spec step(t(), struct(), [struct()]) :: {:ok, t()} | {:error, {:check, atom(), String.t()}}
  def step(checks, command, events) do
    states =
      Map.new(checks.states, fn {projection, state} ->
        {projection, Enum.reduce(events, state, &projection.apply(&2, &1))}
      end)

    triggers = [{:command, command} | Enum.map(events, &{:event, &1})]

    Enum.reduce_while(triggers, {:ok, %{checks | states: states}}, fn trigger, {:ok, checks} ->
      case trigger(checks, trigger) do
        {:ok, checks} -> {:cont, {:ok, checks}}
        {:error, _reason} = failure -> {:halt, failure}
      end
    end)
  end

  defp trigger(checks, {type, %module{} = term}) do
    counters =
      Enum.reduce([:step, type, module], checks.counters, fn key, acc ->
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    step_ctx = %{step_type: type, module: module, command_or_event: term}

    checks.projections
    |> Enum.reduce_while({:ok, counters}, fn projection, {:ok, counters} ->
      state = Map.fetch!(checks.states, projection)

      case ProjectionChecks.step_checks(projection, state, step_ctx, counters) do
        {:ok, counters} ->
          {:cont, {:ok, counters}}

        {:error, name, {exception, _stacktrace}, _counters} ->
          {:halt, {:error, {:check, name, Exception.message(exception)}}}
      end
    end)
    |> case do
      {:ok, counters} -> {:ok, %{checks | counters: counters}}
      failure -> failure
    end
  end

  # --- The schedules this engine runs

  defp supported!(projection) do
    for check <- ProjectionChecks.list(projection), not supported?(check) do
      raise ArgumentError,
            "#{inspect(projection)}.#{check.function_name}/2 declares #{describe(check)}, " <>
              "which is not supported by this engine yet: it runs @check every: N and " <>
              "@check every: CommandModule only"
    end

    :ok
  end

  defp supported?(%{type: :synchronous, trigger: %{type: :every_step}}), do: true
  defp supported?(%{type: :synchronous, trigger: %{type: :every_n, target: :step}}), do: true
  defp supported?(%{type: :synchronous, trigger: %{type: :modules, modules: [_]}}), do: true
  defp supported?(_check), do: false

  defp describe(%{type: :polling}), do: "an @eventually check"
  defp describe(%{trigger: %{type: :at, phase: phase}}), do: "@check at: #{inspect(phase)}"
  defp describe(%{trigger: trigger}), do: "a @check with the schedule #{inspect(trigger)}"
end
