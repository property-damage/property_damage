# Variants of the running example's model, for tests that replay one model's
# journal on another. Each differs from `PropertyDamage.Next.Test.Scheme.Model`
# in one way, named by the module.

defmodule PropertyDamage.Next.Test.Scheme.Variants do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      use PropertyDamage.Next.Model

      alias PropertyDamage.Next.Test.Scheme.Model

      def simulator, do: Model.simulator()
      def command_sequence_projection, do: Model.command_sequence_projection()
      def check_projections, do: Model.check_projections()
    end
  end

  @doc "A `when:` that never holds."
  def never(_state), do: false
end

defmodule PropertyDamage.Next.Test.Scheme.HeavierPayModel do
  @moduledoc false
  # Pay weighs 5 instead of 2.
  use PropertyDamage.Next.Test.Scheme.Variants

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.{Pay, Refund, RefundedTotal}

  def steps do
    StepSpec.normalize([
      {Pay, weight: 5},
      {Refund, weight: 3, when: &Refund.possible?/1, command_opts: [max_share: 0.5]},
      {RefundedTotal, when: &Refund.possible?/1}
    ])
  end
end

defmodule PropertyDamage.Next.Test.Scheme.ReorderedModel do
  @moduledoc false
  # The same specs, with the read listed before the refund.
  use PropertyDamage.Next.Test.Scheme.Variants

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.{Pay, Refund, RefundedTotal}

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {RefundedTotal, when: &Refund.possible?/1},
      {Refund, weight: 3, when: &Refund.possible?/1, command_opts: [max_share: 0.5]}
    ])
  end
end

defmodule PropertyDamage.Next.Test.Scheme.NoRefundModel do
  @moduledoc false
  # Refund's `when:` never holds; nothing else changes.
  use PropertyDamage.Next.Test.Scheme.Variants

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.{Pay, Refund, RefundedTotal, Variants}

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Variants.never/1, command_opts: [max_share: 0.5]},
      {RefundedTotal, when: &Refund.possible?/1}
    ])
  end
end

defmodule PropertyDamage.Next.Test.Scheme.WiderShareModel do
  @moduledoc false
  # Refund's `max_share` option is 0.9 instead of 0.5: same option keys.
  use PropertyDamage.Next.Test.Scheme.Variants

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.{Pay, Refund, RefundedTotal}

  def steps do
    StepSpec.normalize([
      {Pay, weight: 2},
      {Refund, weight: 3, when: &Refund.possible?/1, command_opts: [max_share: 0.9]},
      {RefundedTotal, when: &Refund.possible?/1}
    ])
  end
end

defmodule PropertyDamage.Next.Test.Scheme.OnlyRefundModel do
  @moduledoc false
  # Refunds only: with no payment, no spec is ever eligible.
  use PropertyDamage.Next.Test.Scheme.Variants

  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Scheme.Refund

  def steps, do: StepSpec.normalize([{Refund, when: &Refund.possible?/1}])
end
