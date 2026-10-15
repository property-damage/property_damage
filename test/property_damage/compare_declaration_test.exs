defmodule PropertyDamage.CompareDeclarationTest do
  # Where `@compare` may stand: directly above a public `def name(state, root)`,
  # alone, and never on a check or on the projection's own callbacks. Each
  # misplacement is a compile error naming `@compare`.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Compare

  defmodule UserAttribute do
    @moduledoc false
    # A user's own `@/1`: handles `@tagged` and passes every other attribute to
    # `Kernel.@/1`, so `@compare` through it is a plain module attribute.
    defmacro @{:tagged, _meta, [value]} do
      quote do: Module.put_attribute(__MODULE__, :user_tagged, unquote(value))
    end

    defmacro @expression do
      quote do: Kernel.@(unquote(expression))
    end
  end

  defp compile(body) do
    name = "Declared#{System.unique_integer([:positive])}"

    Compare.compile("""
    defmodule #{inspect(__MODULE__)}.#{name} do
      use PropertyDamage.Model.Projection

    #{body}
    end
    """)
  end

  describe "beside a user's own @ macro" do
    test "importing it next to the projection's @ is a compile error naming the conflict" do
      for imports <- [
            "use PropertyDamage.Model.Projection\n  import #{inspect(UserAttribute)}",
            "import Kernel, except: [@: 1]\n  import #{inspect(UserAttribute)}\n  use PropertyDamage.Model.Projection"
          ] do
        assert {:error, message} =
                 Compare.compile("""
                 defmodule #{inspect(__MODULE__)}.Imported#{System.unique_integer([:positive])} do
                   #{imports}

                   @compare every: 1
                   def observed(s, _root), do: s
                 end
                 """)

        # Elixir 1.17 reports the clash as "imported from both ... call is
        # ambiguous"; later versions as "conflicting @/1 import". Both name
        # the two modules.
        assert message =~ "@/1"
        assert message =~ inspect(UserAttribute)
        assert message =~ "PropertyDamage.Model.Projection.CompareAttribute"
      end
    end

    test "a @compare that reaches Kernel.@ through it is a compile error, never a dropped observation" do
      name = "#{inspect(__MODULE__)}.Uncaptured#{System.unique_integer([:positive])}"

      assert {:error, message} =
               Compare.compile("""
               defmodule #{name} do
                 use PropertyDamage.Model.Projection
                 import PropertyDamage.Model.Projection.CompareAttribute, only: []
                 import #{inspect(UserAttribute)}

                 @tagged :x
                 @compare every: 1
                 def observed(s, _root), do: s
               end
               """)

      assert message =~ name
      assert message =~ "@compare"
      assert message =~ "PropertyDamage.Model.Projection"
    end
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

  describe "a function with several clauses" do
    test "a second @compare on a later clause is a compile error naming the function" do
      assert {:error, message} =
               compile("""
                 @impl true
                 def init, do: %{paid: 0}

                 @impl true
                 def apply(s, _), do: s

                 @compare every: 1
                 def paid(%{paid: 0}, _root), do: 0

                 @compare every: :end
                 def paid(s, _root), do: s.paid
               """)

      assert message =~ "paid/2"
      assert message =~ "a function carries one @compare, written above its first clause"
    end

    test "a single @compare above the first clause is evaluated once per boundary" do
      name = :"compare_declaration_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      projection = Module.concat(__MODULE__, "Clauses#{System.unique_integer([:positive])}")

      assert {:ok, _} =
               Compare.compile("""
               defmodule #{inspect(projection)} do
                 use PropertyDamage.Model.Projection
                 alias PropertyDamage.Test.Compare.Paid

                 @impl true
                 def init, do: %{by: nil, paid: 0}

                 @impl true
                 def apply(s, %Paid{by: by}), do: %{s | by: by, paid: s.paid + 1}
                 def apply(s, _), do: s

                 @compare every: 1
                 def paid(%{paid: 0} = s, root), do: evaluated(s, root, 0)
                 def paid(s, root), do: evaluated(s, root, s.paid)

                 defp evaluated(s, root, value) do
                   send(#{inspect(name)}, {:evaluated, s.by, root.n})
                   value
                 end
               end
               """)

      model =
        Compare.define_model!(Module.concat(projection, Model), [projection], [
          Compare.Pay,
          Compare.Pay
        ])

      targets = [Compare.target("a"), Compare.target("b")]
      assert {:ok, stats} = Compare.run(model, targets, max_commands: 2)
      assert Compare.counts(stats, {projection, :paid}).compared_at == 2

      evaluated = evaluations()
      assert for({:evaluated, "a", n} <- evaluated, do: n) == [0, 1]
      assert for({:evaluated, "b", n} <- evaluated, do: n) == [0, 1]
    end
  end

  defp evaluations do
    receive do
      {:evaluated, _by, _n} = message -> [message | evaluations()]
    after
      0 -> []
    end
  end
end
