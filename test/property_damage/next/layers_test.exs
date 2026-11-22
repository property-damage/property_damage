defmodule PropertyDamage.Next.LayersTest do
  # A layer is a function from specs to specs. A second model reuses the
  # base model's specs through layers and runs on the same engine.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Gen, StepSpec}
  alias PropertyDamage.Next.Test.Scheme.{Adapter, Model, Pay, Refund}
  alias PropertyDamage.Next.Test.Terms

  defmodule Layers do
    @moduledoc false

    # Refunds may take most of the payment instead of half of it.
    def wide_refunds(%StepSpec{command: Refund} = spec),
      do: StepSpec.merge_command_opts(spec, max_share: 0.9)

    def wide_refunds(spec), do: spec

    # Payments are small, so refunds are small too.
    def small_payments(%StepSpec{command: Pay} = spec),
      do: StepSpec.put_command_field(spec, :amount, Gen.integer(2..20))

    def small_payments(spec), do: spec

    def other_when(%StepSpec{} = spec), do: %{spec | when: fn _state -> true end}
  end

  defmodule LayeredModel do
    @moduledoc false
    # The base model's specs, narrowed by two layers.
    use PropertyDamage.Next.Model

    alias PropertyDamage.Next.LayersTest.Layers
    alias PropertyDamage.Next.StepSpec
    alias PropertyDamage.Next.Test.Scheme.Model

    def steps,
      do: StepSpec.transform(Model.steps(), [&Layers.wide_refunds/1, &Layers.small_payments/1])

    def simulator, do: Model.simulator()
    def command_sequence_projection, do: Model.command_sequence_projection()
    def check_projections, do: Model.check_projections()
  end

  describe "a layer that changes when:" do
    test "raises, naming the layer, because a function has no identity to match on" do
      error =
        Terms.raised(fn -> StepSpec.transform(Model.steps(), &Layers.other_when/1) end)

      assert %ArgumentError{} = error
      assert Exception.message(error) =~ "when:"
      assert Exception.message(error) =~ "other_when"
    end

    test "does not raise when the layer leaves when: as it was" do
      specs = StepSpec.transform(Model.steps(), &Layers.wide_refunds/1)

      assert Enum.map(specs, & &1.when) == Enum.map(Model.steps(), & &1.when)
    end
  end

  describe "a model that reuses another model's specs through layers" do
    test "keeps the base specs' ids, weights and when: functions" do
      layered = LayeredModel.steps()
      base = Model.steps()

      assert Enum.map(layered, & &1.weight) == Enum.map(base, & &1.weight)
      assert Enum.map(layered, & &1.when) == Enum.map(base, & &1.when)
    end

    test "runs and passes against a correct system" do
      assert {:ok, %{plans: 5}} =
               Next.run(
                 model: LayeredModel,
                 adapter: Adapter,
                 seed: 3,
                 max_steps: 8,
                 max_plans: 5
               )
    end

    test "finds a failure and shrinks it to the refund that exposes it" do
      assert {:error, %Failure{} = failure} =
               Next.run(
                 model: LayeredModel,
                 adapter: Adapter,
                 seed: 4,
                 max_steps: 12,
                 max_plans: 50,
                 config: %{fault: :refund_error}
               )

      assert failure.reason == {:adapter_error, :refund_unavailable}
      assert Enum.map(failure.plan.steps, & &1.command.__struct__) == [Pay, Refund]
      assert failure.shrink_runs > 0

      amounts = for %Pay{amount: amount} <- Enum.map(failure.plan.steps, & &1.command), do: amount
      assert Enum.all?(amounts, &(&1 in 2..20))
    end
  end
end
