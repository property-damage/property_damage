defmodule PropertyDamage.ProjectionMacroTest do
  @moduledoc """
  Compile-time hazards in the check-projection DSL (`use
  PropertyDamage.Model.Projection`): dangling/misplaced `@check`, multi-clause
  checks, and mistyped trigger values that would silently never fire.
  """
  use ExUnit.Case, async: true

  defp eval(src), do: Code.eval_string(src)

  test "a dangling @check above init/0 raises rather than attaching to the wrong def" do
    assert_raise CompileError, ~r/dangling @check/, fn ->
      eval("""
      defmodule PDMT.DanglingBeforeInit do
        use PropertyDamage.Model.Projection
        @check every: 1
        def init, do: %{}
        def apply(s, _), do: s
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "a trailing @check with no following check function raises" do
    assert_raise CompileError, ~r/dangling @check/, fn ->
      eval("""
      defmodule PDMT.TrailingTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        def apply(s, _), do: s
        @check every: 1
      end
      """)
    end
  end

  test "a multi-clause assert_ function compiles and registers exactly one check" do
    # Exercise both clauses inside the eval'd source so the checks on a
    # module that only exists at runtime carry no compile-time reference (which
    # would warn as undefined).
    {result, _} =
      eval("""
      defmodule PDMT.MultiClause do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @check every: 1
        def assert_x(_s, %{a: _}), do: :ok
        def assert_x(_s, _), do: :ok
      end

      {PDMT.MultiClause.__checks__(), PDMT.MultiClause.assert_x(%{}, %{a: 1}),
       PDMT.MultiClause.assert_x(%{}, %{})}
      """)

    {checks, clause_with_map, clause_catchall} = result

    assert [%{function_name: :assert_x, type: :synchronous}] = checks
    # both clauses are live
    assert clause_with_map == :ok
    assert clause_catchall == :ok
  end

  test "a mistyped atom trigger value raises instead of silently never firing" do
    assert_raise ArgumentError, ~r/never fires|not a module/, fn ->
      eval("""
      defmodule PDMT.MistypedValue do
        use PropertyDamage.Model.Projection
        @check every: :commnd
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "an unrecognized at: phase raises instead of normalizing to a never-firing trigger" do
    assert_raise ArgumentError, ~r/:startup or :teardown/, fn ->
      eval("""
      defmodule PDMT.BadAtPhase do
        use PropertyDamage.Model.Projection
        @check at: :end_of_sequence
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "@check at: :teardown compiles and records the phase, type stays :synchronous" do
    {result, _} =
      eval("""
      defmodule PDMT.TeardownTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @check at: :teardown
        def assert_settled_ok(_s,_), do: :ok
      end
      PDMT.TeardownTrigger.__checks__()
      """)

    assert [
             %{
               name: :settled_ok,
               function_name: :assert_settled_ok,
               type: :synchronous,
               trigger: %{type: :at, phase: :teardown}
             }
           ] = result
  end

  test "@check at: :startup compiles and records the phase" do
    {result, _} =
      eval("""
      defmodule PDMT.StartupTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @check at: :startup
        def assert_initial_ok(_s,_), do: :ok
      end
      PDMT.StartupTrigger.__checks__()
      """)

    assert [%{trigger: %{type: :at, phase: :startup}, type: :synchronous}] = result
  end

  test "declaring both every: and at: on one @check raises (one timing per check)" do
    assert_raise CompileError, ~r/only.*one timing|both every: and at:/, fn ->
      eval("""
      defmodule PDMT.TwoTimings do
        use PropertyDamage.Model.Projection
        @check every: 1, at: :teardown
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "a trailing @check at: with no following check function raises" do
    assert_raise CompileError, ~r/dangling @check/, fn ->
      eval("""
      defmodule PDMT.TrailingAt do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        def apply(s, _), do: s
        @check at: :teardown
      end
      """)
    end
  end

  test "a zero count in {N, target} raises instead of crashing later with ArithmeticError" do
    assert_raise ArgumentError, ~r/positive/, fn ->
      eval("""
      defmodule PDMT.ZeroCount do
        use PropertyDamage.Model.Projection
        @check every: {0, :command}
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "a negative count in {N, target} raises" do
    assert_raise ArgumentError, ~r/positive/, fn ->
      eval("""
      defmodule PDMT.NegCount do
        use PropertyDamage.Model.Projection
        @check every: {-2, :event}
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "stacking two @check attributes on one check raises" do
    assert_raise CompileError, ~r/multiple @check/, fn ->
      eval("""
      defmodule PDMT.DoubleTrigger do
        use PropertyDamage.Model.Projection
        @check every: 1
        @check every: 2
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "combining @check and @eventually on one check raises" do
    assert_raise CompileError, ~r/cannot combine both @check and @eventually/, fn ->
      eval("""
      defmodule PDMT.TriggerAndPoll do
        defmodule Ev do
          defstruct []
        end
        use PropertyDamage.Model.Projection
        @check every: 1
        @eventually after: Ev, timeout: 1, interval: 1
        def assert_x(_s,_), do: fn _ -> true end
      end
      """)
    end
  end

  test "polling check metadata carries function_name and a stripped name, like synchronous ones" do
    {result, _} =
      eval("""
      defmodule PDMT.UnifiedPollEvent do
        defstruct []
      end
      defmodule PDMT.UnifiedPoll do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @eventually after: PDMT.UnifiedPollEvent, timeout: 1, interval: 1
        def assert_eventually(_s, _), do: fn _ -> true end
      end
      PDMT.UnifiedPoll.__checks__()
      """)

    assert [%{name: :eventually, function_name: :assert_eventually, type: :polling}] = result
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
        @check every: PDMT.RealModuleEvent
        def assert_x(_s,_), do: :ok
      end
      PDMT.RealModuleTrigger.__checks__()
      """)

    assert [%{trigger: %{type: :modules, modules: [PDMT.RealModuleEvent]}}] = result
  end
end
