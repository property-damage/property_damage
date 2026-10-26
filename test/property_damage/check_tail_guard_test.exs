defmodule PropertyDamage.CheckTailGuardTest do
  # The retired `if condition, do: fail!(...)` idiom returns `nil` when the
  # check passes, which DR-052 reads as a failure. A `@check` clause whose last
  # expression is an `if` or `unless` without `else` is therefore a compile
  # error naming the clause and the rewrite (DR-052 item 3).
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Compare

  defp compile(body) do
    name = "Guarded#{System.unique_integer([:positive])}"

    Compare.compile("""
    defmodule #{inspect(__MODULE__)}.#{name} do
      use PropertyDamage.Model.Projection

    #{body}
    end
    """)
  end

  @rewrite "write `condition or fail!(...)`"

  test "a one-line if without else is a compile error naming the clause and the rewrite" do
    assert {:error, message} =
             compile("""
               @check every: 1
               def net_covers_fees(state, _), do: if(state.net < state.fees, do: PropertyDamage.fail!("short"))
             """)

    assert message =~
             "`net_covers_fees/2` ends in `if` without `else`, which returns `nil` when the " <>
               "check passes; " <> @rewrite
  end

  test "a block if without else as the last expression is a compile error" do
    assert {:error, message} =
             compile("""
               @check every: 1
               def net_covers_fees(state, _) do
                 short? = state.net < state.fees

                 if short? do
                   PropertyDamage.fail!("short")
                 end
               end
             """)

    assert message =~ "`net_covers_fees/2` ends in `if` without `else`"
  end

  test "an unless without else is a compile error naming unless" do
    assert {:error, message} =
             compile("""
               @check at: :teardown
               def balanced(state, _phase) do
                 unless state.debits == state.credits do
                   PropertyDamage.fail!("unbalanced")
                 end
               end
             """)

    assert message =~ "`balanced/2` ends in `unless` without `else`"
    assert message =~ @rewrite
  end

  test "a later clause of a multi-clause check is guarded too" do
    assert {:error, message} =
             compile("""
               @check every: 1
               def positive(_state, %{amount: amount}), do: amount > 0 or PropertyDamage.fail!("neg")
               def positive(state, _), do: if(state.broken, do: PropertyDamage.fail!("broken"))
             """)

    assert message =~ "`positive/2` ends in `if` without `else`"
  end

  test "an if with else compiles" do
    assert {:ok, _modules} =
             compile("""
               @check every: 1
               def net_covers_fees(state, _) do
                 if state.net < state.fees, do: PropertyDamage.fail!("short"), else: :ok
               end
             """)
  end

  test "an if that is not the last expression compiles" do
    assert {:ok, _modules} =
             compile("""
               @check every: 1
               def logged(state, _) do
                 if state.debug, do: IO.puts("checked")
                 :ok
               end
             """)
  end

  test "the guard is for checks: an @eventually or a helper may end in if" do
    assert {:ok, _modules} =
             compile("""
               @eventually after: Foo, timeout: 1, interval: 1
               def confirmed(_state, _event) do
                 if Foo, do: fn s -> s end
               end

               def helper(state, _), do: if(state.x, do: :x)
             """)
  end
end
