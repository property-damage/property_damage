defmodule PropertyDamage.Next.Test.LayerJournal do
  @moduledoc false
  # Layers and models for the journal tests of layered models. The models are
  # compiled with the test support, so a peer VM that shares the code paths
  # loads them by name.

  alias PropertyDamage.Next.{Gen, StepSpec}
  alias PropertyDamage.Next.Test.Scheme.{Model, Pay, Refund}

  defmodule Layers do
    @moduledoc false

    # A plain generator assign on payments.
    def tenant(%StepSpec{command: Pay} = spec),
      do: StepSpec.assign(spec, :tenant, Gen.integer(1..9))

    def tenant(spec), do: spec

    # An assign drawn from the drawn refund.
    def hint(%StepSpec{command: Refund} = spec),
      do:
        StepSpec.assign_from_command(spec, :hint, fn %Refund{amount: n} ->
          Gen.integer(1..max(n, 1))
        end)

    def hint(spec), do: spec

    # A second assign-only layer.
    def delay(%StepSpec{command: Pay} = spec),
      do: StepSpec.assign(spec, :delay, Gen.boolean())

    def delay(spec), do: spec

    # A layer that changes a weight.
    def heavy_pay(%StepSpec{command: Pay} = spec), do: %{spec | weight: 5}
    def heavy_pay(spec), do: spec

    # A layer that changes a command option's value, not its key.
    def wide_refunds(%StepSpec{command: Refund} = spec),
      do: StepSpec.merge_command_opts(spec, max_share: 0.9)

    def wide_refunds(spec), do: spec
  end

  defmodule Base do
    @moduledoc false
    # The scheme model with a tenant assign and a hint assign.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.Test.LayerJournal.Layers

    def steps, do: StepSpec.transform(Model.steps(), [&Layers.tenant/1, &Layers.hint/1])
    def simulator, do: Model.simulator()
    def command_sequence_projection, do: Model.command_sequence_projection()
    def check_projections, do: Model.check_projections()
  end

  # Each variant is the base with one layer more or less.
  for {name, layers} <- [
        AddsAssignLayer: [:tenant, :hint, :delay],
        AddsWeightLayer: [:tenant, :hint, :heavy_pay],
        AddsOptionLayer: [:tenant, :hint, :wide_refunds],
        DropsHintLayer: [:tenant],
        DropsAllLayers: []
      ] do
    funs = Enum.map(layers, &Function.capture(Layers, &1, 1))
    module = Module.concat(__MODULE__, name)

    defmodule module do
      @moduledoc false
      use PropertyDamage.Next.Model

      @funs funs
      def steps, do: StepSpec.transform(Model.steps(), @funs)
      def simulator, do: Model.simulator()
      def command_sequence_projection, do: Model.command_sequence_projection()
      def check_projections, do: Model.check_projections()
    end
  end
end
