defmodule PropertyDamage.Next.Model do
  @moduledoc """
  The behaviour of a model for the new engine.

  A model lists its step specs in `c:steps/0`, built with
  `PropertyDamage.Next.StepSpec.normalize/1` and changed by layers. It
  names the simulator that predicts each command's events (a module
  implementing `PropertyDamage.Model.Simulator`), the projection that folds
  the predicted events into the state generation reads, whose checks run
  during execution, and further projections whose checks run (none by
  default). A model may also state, in `c:expansions/0`, other ways to run
  some of its commands; each plan then runs twice and the two executions
  are compared after each step.

      defmodule PaymentsModel do
        use PropertyDamage.Next.Model

        alias PropertyDamage.Next.StepSpec

        def steps, do: StepSpec.normalize([{Pay, weight: 2}, {Refund, when: &Refund.possible?/1}])
        def simulator, do: PaymentsSimulator
        def command_sequence_projection, do: Payments
        def check_projections, do: [Payments]
      end
  """

  alias PropertyDamage.Next.StepSpec

  @doc "The step specs, in the order that gives each spec its id."
  @callback steps() :: [StepSpec.t()]

  @doc "The module that predicts the events of a command from the predicted state."
  @callback simulator() :: module()

  @doc """
  The projection that folds predicted events into the state generation
  reads. During execution it also folds the real events, and its checks run
  as those of a check projection do.
  """
  @callback command_sequence_projection() :: module()

  @doc """
  Further projections whose checks run during execution. Naming the
  command-sequence projection here too runs its checks once, not twice.
  """
  @callback check_projections() :: [module()]

  @doc """
  The paths of the listed commands: each a command module of the model's
  specs, once, with a function of two arguments.

  The function receives the step's command as drawn, which may hold
  placeholders, and the predicted state the command's generator saw. It
  returns the list of paths, each a way to run that command: the plain
  path, the command alone as `[command]`, first, then any number of others.
  A path is a non-empty list of command structs, or `{generators, builder}`:
  `generators` is a plain map from an atom name to a generator, drawn by PD
  under the step, and `builder` is a function given the map of drawn values
  that returns the path's non-empty list of command structs.

  A path may hold commands of modules that no spec draws, such as a read
  that exists only to split a write in two. Two parts of the model then
  treat such a command differently:

    * The adapter runs it: the variant passes every command of the picked
      path to `execute/3`, so the adapter needs a clause for each.
    * The simulator never sees it. PD predicts each step from the step's
      command as drawn, whichever path is picked, so the simulator needs
      clauses only for the commands that specs draw. The paths of a command
      are meant to leave the system in the state the command alone leaves
      it in; a path that does not is the difference the comparison reports.

  A model that states paths runs each plan twice, against two fresh setups
  of its adapter: the reference runs every step plain, and the variant runs
  the path picked for each step, whose pick PD draws. Its `@compare every:
  1` observations are compared between the two after each step (see
  `PropertyDamage.Next.run/1`).
  """
  @callback expansions() :: [{module(), (struct(), term() -> [path])}]

  @typedoc "One way to run a command: a list of commands, or a draw and a builder."
  @type path :: [struct()] | {%{atom() => term()}, (map() -> [struct()])}

  @optional_callbacks check_projections: 0, expansions: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Next.Model

      def check_projections, do: []
      defoverridable check_projections: 0
    end
  end

  @doc """
  The model's specs with their ids set: each spec's position in the list,
  counted from 1. Raises if `steps/0` returns anything but a list of specs.
  """
  @spec specs!(module()) :: [StepSpec.t()]
  def specs!(model) when is_atom(model) do
    case model.steps() do
      specs when is_list(specs) ->
        specs |> Enum.map(&spec!(&1, model)) |> Enum.with_index(1) |> Enum.map(&with_id/1)

      other ->
        raise ArgumentError,
              "#{inspect(model)}.steps/0 must return a list, got: #{inspect(other)}"
    end
  end

  defp spec!(%StepSpec{} = spec, _model), do: spec

  defp spec!(other, model) do
    raise ArgumentError,
          "#{inspect(model)}.steps/0 must return %StepSpec{} structs (build them with " <>
            "StepSpec.normalize/1), got: #{inspect(other)}"
  end

  defp with_id({spec, position}), do: %{spec | id: position}

  @doc """
  The paths functions of `model` by command module, or `nil` for a model
  that does not export `c:expansions/0`. Raises `ArgumentError` naming the
  model unless `expansions/0` returns a list of `{module, fun/2}` pairs,
  each module the command module of one of `specs` and none listed twice.
  """
  @spec expansions!(module(), [StepSpec.t()]) :: %{module() => function()} | nil
  def expansions!(model, specs) when is_atom(model) do
    if Code.ensure_loaded?(model) and function_exported?(model, :expansions, 0),
      do: statement!(model.expansions(), model, specs)
  end

  defp statement!(statement, model, specs) when is_list(statement) do
    commands = MapSet.new(specs, & &1.command)

    Enum.reduce(statement, %{}, fn
      {module, fun} = pair, acc when is_atom(module) and is_function(fun, 2) ->
        cond do
          module not in commands ->
            statement_error!(model, "names #{inspect(module)}, which no spec draws", pair)

          Map.has_key?(acc, module) ->
            statement_error!(model, "lists #{inspect(module)} twice", pair)

          true ->
            Map.put(acc, module, fun)
        end

      other, _acc ->
        statement_error!(model, "holds an element that is not a {module, fun/2} pair", other)
    end)
  end

  defp statement!(other, model, _specs) do
    raise ArgumentError,
          "#{inspect(model)}.expansions/0 must return a list of {command module, fun/2} " <>
            "pairs, got: #{inspect(other)}"
  end

  defp statement_error!(model, problem, element) do
    raise ArgumentError,
          "#{inspect(model)}.expansions/0 #{problem}: #{inspect(element)}. It lists each " <>
            "command module of the model's specs at most once, with a function of the " <>
            "command and the predicted state"
  end
end
