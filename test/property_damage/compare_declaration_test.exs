defmodule PropertyDamage.CompareDeclarationTest do
  # Where `@compare` may stand: directly above a public `def name(state, root)`,
  # alone, and never on a check or on the projection's own callbacks. Each
  # misplacement is a compile error naming `@compare`.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Compare

  defp compile(body) do
    name = "Declared#{System.unique_integer([:positive])}"

    Compare.compile("""
    defmodule #{inspect(__MODULE__)}.#{name} do
      use PropertyDamage.Model.Projection

    #{body}
    end
    """)
  end

  test "a @compare with no function after it is a compile error" do
    assert {:error, message} =
             compile("""
               @impl true
               def apply(s, _), do: s

               @compare every: 1
             """)

    assert message =~ "dangling @compare"
  end

  test "a @compare above a private function is a compile error" do
    assert {:error, message} =
             compile("""
               @compare every: 1
               defp observed(s, _root), do: s
             """)

    assert message =~ "dangling @compare"
  end

  test "a @compare above apply/2 is a compile error" do
    assert {:error, message} =
             compile("""
               @compare every: 1
               @impl true
               def apply(s, _), do: s
             """)

    assert message =~ "@compare"
    assert message =~ "apply/2"
  end

  test "a @compare on a @check function is a compile error" do
    assert {:error, message} =
             compile("""
               @compare every: 1
               @check every: 1
               def observed(_s, _event), do: :ok
             """)

    assert message =~ "@compare"
    assert message =~ "@check"
  end

  test "two @compare attributes on one function are a compile error" do
    assert {:error, message} =
             compile("""
               @compare every: 1
               @compare every: :end
               def observed(s, _root), do: s
             """)

    assert message =~ "multiple @compare"
  end

  test "a @compare without a keyword list is a compile error" do
    assert {:error, message} =
             compile("""
               @compare :sometimes
               def observed(s, _root), do: s
             """)

    assert message =~ "@compare takes a keyword list"
  end

  test "a well-placed @compare declares its key and schedule" do
    assert {:ok, [projection | _]} =
             compile("""
               @compare every: :end
               def observed(s, _root), do: s

               def helper, do: :ok
             """)

    assert projection.__compares__() == [
             %{name: :observed, schedule: %{roots: :none, end: true}}
           ]
  end
end
