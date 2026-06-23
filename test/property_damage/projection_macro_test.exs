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
        def assert_x(_s,_), do: :ok
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
        def assert_x(_s,%{a: _}), do: :ok
        def assert_x(_s,_), do: :ok
      end
      PDMT.MultiClause.__assertions__()
      """)

    assert [%{function_name: :assert_x, type: :synchronous}] = result
    # both clauses are live. Call via a runtime-resolved module + apply/3 so the
    # compiler does not warn about a static reference to this eval'd-at-runtime
    # module (which does not exist at compile time).
    mod = Module.concat([:PDMT, :MultiClause])
    assert apply(mod, :assert_x, [%{}, %{a: 1}]) == :ok
    assert apply(mod, :assert_x, [%{}, %{}]) == :ok
  end

  test "a mistyped atom trigger value raises instead of silently never firing" do
    assert_raise ArgumentError, ~r/never fires|not a module/, fn ->
      eval("""
      defmodule PDMT.MistypedValue do
        use PropertyDamage.Model.Projection
        @trigger every: :commnd
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
        @trigger at: :end_of_sequence
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "@trigger at: :teardown compiles and records the phase, type stays :synchronous" do
    {result, _} =
      eval("""
      defmodule PDMT.TeardownTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @trigger at: :teardown
        def assert_settled_ok(_s,_), do: :ok
      end
      PDMT.TeardownTrigger.__assertions__()
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

  test "@trigger at: :startup compiles and records the phase" do
    {result, _} =
      eval("""
      defmodule PDMT.StartupTrigger do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @trigger at: :startup
        def assert_initial_ok(_s,_), do: :ok
      end
      PDMT.StartupTrigger.__assertions__()
      """)

    assert [%{trigger: %{type: :at, phase: :startup}, type: :synchronous}] = result
  end

  test "declaring both every: and at: on one @trigger raises (one timing per assertion)" do
    assert_raise CompileError, ~r/only.*one timing|both every: and at:/, fn ->
      eval("""
      defmodule PDMT.TwoTimings do
        use PropertyDamage.Model.Projection
        @trigger every: 1, at: :teardown
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "a trailing @trigger at: with no following assertion function raises" do
    assert_raise CompileError, ~r/dangling @trigger/, fn ->
      eval("""
      defmodule PDMT.TrailingAt do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        def apply(s, _), do: s
        @trigger at: :teardown
      end
      """)
    end
  end

  test "a zero count in {N, target} raises instead of crashing later with ArithmeticError" do
    assert_raise ArgumentError, ~r/positive/, fn ->
      eval("""
      defmodule PDMT.ZeroCount do
        use PropertyDamage.Model.Projection
        @trigger every: {0, :command}
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
        @trigger every: {-2, :event}
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "stacking two @trigger attributes on one assertion raises" do
    assert_raise CompileError, ~r/multiple @trigger/, fn ->
      eval("""
      defmodule PDMT.DoubleTrigger do
        use PropertyDamage.Model.Projection
        @trigger every: 1
        @trigger every: 2
        def assert_x(_s,_), do: :ok
      end
      """)
    end
  end

  test "combining @trigger and @poll_state on one assertion raises" do
    assert_raise CompileError, ~r/both @trigger and @poll_state|cannot combine/, fn ->
      eval("""
      defmodule PDMT.TriggerAndPoll do
        defmodule Ev do
          defstruct []
        end
        use PropertyDamage.Model.Projection
        @trigger every: 1
        @poll_state after: Ev, timeout: 1, interval: 1
        def assert_x(_s,_), do: fn _ -> true end
      end
      """)
    end
  end

  test "polling assertion metadata carries function_name and a stripped name, like synchronous ones" do
    {result, _} =
      eval("""
      defmodule PDMT.UnifiedPollEvent do
        defstruct []
      end
      defmodule PDMT.UnifiedPoll do
        use PropertyDamage.Model.Projection
        def init, do: %{}
        @poll_state after: PDMT.UnifiedPollEvent, timeout: 1, interval: 1
        def assert_eventually(_s, _), do: fn _ -> true end
      end
      PDMT.UnifiedPoll.__assertions__()
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
        @trigger every: PDMT.RealModuleEvent
        def assert_x(_s,_), do: :ok
      end
      PDMT.RealModuleTrigger.__assertions__()
      """)

    assert [%{trigger: %{type: :modules, modules: [PDMT.RealModuleEvent]}}] = result
  end
end
