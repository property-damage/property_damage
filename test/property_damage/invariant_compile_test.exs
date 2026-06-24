defmodule PropertyDamage.InvariantCompileTest do
  @moduledoc """
  Compile-time structural validations for invariant declarations (DR-026):
  duplicate id, dangling validates:, and the static-vacuity warning. These are
  resolved at @before_compile, so they are exercised by compiling fixture
  projections at runtime.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "a duplicate invariant id is a CompileError" do
    assert_raise CompileError, ~r/duplicate invariant id/, fn ->
      Code.eval_string("""
      defmodule PropertyDamage.InvariantCompileTest.Dup do
        use PropertyDamage.Model.Projection

        @invariant id: :balanced
        @invariant id: :balanced

        @trigger every: 1, validates: :balanced
        def assert_x(_state, _), do: :ok
      end
      """)
    end
  end

  test "a dangling validates: (undeclared id) is a CompileError" do
    assert_raise CompileError, ~r/validates: :nope.*no invariant/s, fn ->
      Code.eval_string("""
      defmodule PropertyDamage.InvariantCompileTest.Dangling do
        use PropertyDamage.Model.Projection

        @trigger every: 1, validates: :nope
        def assert_x(_state, _), do: :ok
      end
      """)
    end
  end

  test "a declared-but-unchecked invariant emits a static-vacuity warning" do
    output =
      capture_io(:stderr, fn ->
        Code.eval_string("""
        defmodule PropertyDamage.InvariantCompileTest.Vacuous do
          use PropertyDamage.Model.Projection

          @invariant id: :unverified, description: "Nothing checks this"

          @trigger every: 1
          def assert_other(_state, _), do: :ok
        end
        """)
      end)

    assert output =~ "unverified"
    assert output =~ "statically vacuous"
  end

  test "declaring both id: and validates: on one assertion is a CompileError" do
    assert_raise CompileError, ~r/both id: and validates:/, fn ->
      Code.eval_string("""
      defmodule PropertyDamage.InvariantCompileTest.Both do
        use PropertyDamage.Model.Projection

        @trigger every: 1, id: :x, validates: :y
        def assert_x(_state, _), do: :ok
      end
      """)
    end
  end
end
