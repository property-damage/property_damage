defmodule PropertyDamage.Next.Model do
  @moduledoc """
  The behaviour of a model for the new engine.

  A model lists its step specs in `c:steps/0`, built with
  `PropertyDamage.Next.StepSpec.normalize/1` and changed by layers. It
  names the simulator that predicts each command's events (a module
  implementing `PropertyDamage.Model.Simulator`), the projection that folds
  the predicted events into the state generation reads, and the
  projections whose checks run during execution (none by default).

      defmodule PaymentsModel do
        use PropertyDamage.Next.Model

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

  @doc "The projection that folds predicted events into the state generation reads."
  @callback command_sequence_projection() :: module()

  @doc "The projections whose checks run during execution."
  @callback check_projections() :: [module()]

  @optional_callbacks check_projections: 0

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
end
