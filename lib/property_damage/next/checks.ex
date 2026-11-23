defmodule PropertyDamage.Next.Checks do
  @moduledoc false
  # The checks an execution evaluates: the `@check` functions of the model's
  # check projections and of its command-sequence projection, each projection
  # folding the real events the adapter returns. A projection named in both
  # roles is one projection: its state is folded once and its checks run
  # once per trigger.
  #
  # This engine runs two schedules: `every: N`, sampled over the commands and
  # events executed so far (a command counts one, and so does each of its
  # events, as in today's engine), and `every: Module`, after each command or
  # event of that module. Loading a model whose projections declare any other
  # check form raises, so no check is skipped without a word.
  #
  # A `@compare` observation compares the two executions of a model that
  # states paths, after each step, so it loads only as `@compare every: 1`
  # and only on a model that exports `expansions/0`. Any other `@compare`
  # form raises on every model, and so does `every: 1` on a model without
  # paths, which has one execution and nothing to compare it with.
  #
  # After a step, every projection first folds all of the step's events; then
  # the checks the command triggers run, then those each event triggers, in
  # event order. A check fails by returning `nil` or `false`, by returning
  # `{:fail, message}`, or by raising (`PropertyDamage.fail!/2` raises); the
  # verdict is read by today's check runner.

  alias PropertyDamage.Model.Projection.Checks, as: ProjectionChecks

  @type t :: %{
          projections: [module()],
          states: map(),
          counters: map(),
          compares: [{module(), atom(), (term(), term() -> term())}]
        }

  @doc """
  The projections whose checks run: the check projections of `model`, then
  its command-sequence projection unless it is one of them. Raises
  `ArgumentError` unless every check they declare has a schedule this engine
  runs, and every `@compare` they declare is `every: 1` on a model that
  exports `expansions/0`.
  """
  @spec load!(module()) :: [module()]
  def load!(model) do
    projections = model.check_projections()

    unless is_list(projections) and Enum.all?(projections, &is_atom/1) do
      raise ArgumentError,
            "#{inspect(model)}.check_projections/0 must return a list of projection " <>
              "modules, got: #{inspect(projections)}"
    end

    projections = Enum.uniq(projections ++ [model.command_sequence_projection()])
    paths? = Code.ensure_loaded?(model) and function_exported?(model, :expansions, 0)
    Enum.each(projections, &supported!(&1, model, paths?))
    projections
  end

  @doc """
  The state of a fresh execution: every projection at `init/0`, and the
  `@compare` observations of the projections, in projection order then
  declaration order, each with its relation.
  """
  @spec init([module()]) :: t()
  def init(projections) do
    %{
      projections: projections,
      states: Map.new(projections, &{&1, &1.init()}),
      counters: %{step: 0, command: 0, event: 0},
      compares: observations(projections)
    }
  end

  defp observations(projections) do
    for projection <- projections, %{name: name} <- compares(projection) do
      {projection, name, projection.__compare_using__(name)}
    end
  end

  @doc """
  Evaluates every `@compare` observation on the reference's state and on
  the variant's, each given its execution's concrete command of the step,
  and judges the variant's value against the reference's by the
  observation's relation: `==` without `using:`, else the relation's
  verdict, where only `true` agrees. Returns `:ok`, or the first
  observation that disagrees as `{:diverged, name, step_key, reference_value,
  variant_value}`. An observation or a relation that raises raises out of
  this function.
  """
  @spec compare(t(), t(), struct(), struct(), term()) :: :ok | {:error, tuple()}
  def compare(reference, variant, reference_root, variant_root, step_key) do
    Enum.find_value(reference.compares, :ok, fn {projection, name, relation} ->
      reference_value = observe(reference, projection, name, reference_root)
      variant_value = observe(variant, projection, name, variant_root)

      if relation.(reference_value, variant_value) != true,
        do: {:error, {:diverged, name, step_key, reference_value, variant_value}}
    end)
  end

  defp observe(checks, projection, name, root),
    do: apply(projection, name, [Map.fetch!(checks.states, projection), root])

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

  defp supported!(projection, model, paths?) do
    for check <- ProjectionChecks.list(projection), not supported?(check) do
      raise ArgumentError,
            "#{inspect(projection)}.#{check.function_name}/2 declares #{describe(check)}, " <>
              "which is not supported by this engine yet: it runs @check every: N and " <>
              "@check every: CommandModule only"
    end

    for %{name: name, schedule: schedule} <- compares(projection) do
      cond do
        schedule != %{roots: :all, end: false} ->
          raise ArgumentError,
                "#{inspect(projection)}.#{name}/2 declares @compare with the schedule " <>
                  "#{inspect(schedule)}, which is not supported by this engine yet: it " <>
                  "compares the two executions of a model that states paths after every " <>
                  "step only, as @compare every: 1"

        not paths? ->
          raise ArgumentError,
                "#{inspect(projection)}.#{name}/2 declares @compare every: 1, but " <>
                  "#{inspect(model)} does not export expansions/0: a model without paths " <>
                  "runs each plan once, so there is nothing to compare"

        true ->
          :ok
      end
    end

    :ok
  end

  defp compares(projection) do
    if Code.ensure_loaded?(projection) and function_exported?(projection, :__compares__, 0),
      do: projection.__compares__(),
      else: []
  end

  defp supported?(%{type: :synchronous, trigger: %{type: :every_step}}), do: true
  defp supported?(%{type: :synchronous, trigger: %{type: :every_n, target: :step}}), do: true
  defp supported?(%{type: :synchronous, trigger: %{type: :modules, modules: [_]}}), do: true
  defp supported?(_check), do: false

  defp describe(%{type: :polling}), do: "an @eventually check"
  defp describe(%{trigger: %{type: :at, phase: phase}}), do: "@check at: #{inspect(phase)}"
  defp describe(%{trigger: trigger}), do: "a @check with the schedule #{inspect(trigger)}"
end
