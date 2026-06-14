defmodule PropertyDamage.ProjectionMacroTest do
  @moduledoc """
  Compile-time hazards in the assertion-projection DSL (`use
  PropertyDamage.Model.Projection`): dangling/misplaced `@trigger`, multi-clause
  assertions, and mistyped trigger values that would silently never fire.
  """
  use ExUnit.Case, async: true

  defp eval(src), do: Code.eval_string(src)

  test "a dangling @trigger above init/0 raises rather than attaching to the wrong def" do
    assert_raise CompileError, ~r/dangling @trigger/, fn ->
      eval("""
      defmodule PDMT.DanglingBeforeInit do
        use PropertyDamage.Model.Projection
        @trigger every: 1
        def init, do: %{}
        def apply(s, _), do: s
        def assert_x(s, _), do: :ok
      end
      """)
    end
  end

  test "a trailing @trigger with no following assertion function raises" do
    assert_raise CompileError, ~r/dangling @trigger/, fn ->
      eval("""
      defmodule PDMT.TrailingTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        def apply(s, _), do: s
        @trigger every: 1
      end
      """)
    end
  end

  test "a multi-clause assert_ function compiles and registers exactly one assertion" do
    {result, _} =
      eval("""
      defmodule PDMT.MultiClause do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @trigger every: 1
        def assert_x(s, %{a: _}), do: :ok
        def assert_x(s, _), do: :ok
      end
      PDMT.MultiClause.__assertions__()
      """)

    assert [%{function_name: :assert_x, type: :synchronous}] = result
    # both clauses are live
    assert PDMT.MultiClause.assert_x(%{}, %{a: 1}) == :ok
    assert PDMT.MultiClause.assert_x(%{}, %{}) == :ok
  end

  test "a mistyped atom trigger value raises instead of silently never firing" do
    assert_raise ArgumentError, ~r/never fires|not a module/, fn ->
      eval("""
      defmodule PDMT.MistypedValue do
        use PropertyDamage.Model.Projection
        @trigger every: :commnd
        def assert_x(s, _), do: :ok
      end
      """)
    end
  end

  test "an unsupported trigger key (no :every) raises instead of normalizing to a never-firing trigger" do
    assert_raise ArgumentError, fn ->
      eval("""
      defmodule PDMT.NoEvery do
        use PropertyDamage.Model.Projection
        @trigger at: :end_of_sequence
        def assert_x(s, _), do: :ok
      end
      """)
    end
  end

  test "a real command/event module trigger still works" do
    {result, _} =
      eval("""
      defmodule PDMT.RealModuleEvent do
        defstruct []
      end
      defmodule PDMT.RealModuleTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @trigger every: PDMT.RealModuleEvent
        def assert_x(s, _), do: :ok
      end
      PDMT.RealModuleTrigger.__assertions__()
      """)

    assert [%{trigger: %{type: :modules, modules: [PDMT.RealModuleEvent]}}] = result
  end
end
