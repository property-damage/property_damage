# The macro that defines the small one-purpose models of fixture_models.ex.

defmodule PropertyDamage.Next.Test.Fixtures.Models do
  @moduledoc false
  # `defmodel/2` defines a model whose steps are the given child-style
  # entries, with no events and no checks.

  defmacro defmodel(name, entries) do
    quote do
      defmodule unquote(name) do
        @moduledoc false
        use PropertyDamage.Next.Model

        alias PropertyDamage.Next.StepSpec
        alias PropertyDamage.Next.Test.Fixtures.{EmptyProjection, NullSimulator}

        def steps, do: StepSpec.normalize(unquote(entries))
        def simulator, do: NullSimulator
        def command_sequence_projection, do: EmptyProjection
      end
    end
  end
end
