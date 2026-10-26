defmodule PropertyDamage.VerdictTest do
  # `PropertyDamage.Verdict.read/1` reads the return of a `@check`, an
  # `@eventually` predicate or a `using:` relation with one grammar (DR-052
  # item 1a): the doctests walk the table row by row, these tests pin the
  # wrapping per kind and the check failure message of item 4.
  use ExUnit.Case, async: true

  alias PropertyDamage.CheckFailed
  alias PropertyDamage.ComparisonMismatch
  alias PropertyDamage.Verdict

  doctest PropertyDamage.Verdict

  describe "read/2 for a relation" do
    test "wraps a string reason in a ComparisonMismatch holding both values" do
      assert {:fail, %ComparisonMismatch{left: 1, right: 2, message: "off by one"}} =
               Verdict.read({:fail, "off by one"}, {:relation, 1, 2})
    end

    test "keeps an exception reason as it is" do
      assert {:fail, %ArgumentError{message: "no"}} =
               Verdict.read({:fail, %ArgumentError{message: "no"}}, {:relation, 1, 2})
    end

    test "fails a non-verdict with the nudge, holding both values" do
      assert {:fail, %ComparisonMismatch{left: 1, right: 2, message: message}} =
               Verdict.read({:error, :boom}, {:relation, 1, 2})

      assert message =~ "{:error, :boom}"
      assert message =~ "a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"
    end

    test "reads falsy as falsy, for the caller to build the disagreement" do
      assert Verdict.read(false, {:relation, 1, 2}) == :falsy
      assert Verdict.read(nil, {:relation, 1, 2}) == :falsy
    end
  end

  describe "check/2" do
    test "passes a truthy return" do
      assert Verdict.check(:ok, :net_covers_fees) == :pass
      assert Verdict.check(true, :net_covers_fees) == :pass
    end

    test "fails nil with the message of DR-052 item 4" do
      assert {:fail, %CheckFailed{} = failure} = Verdict.check(nil, :net_covers_fees)

      assert Exception.message(failure) ==
               "check `net_covers_fees` returned `nil`; a check passes by returning a " <>
                 "truthy value: a predicate, `condition or fail!(...)`, or a body that " <>
                 "ends with `:ok`"
    end

    test "fails false with the returned value in the message" do
      assert {:fail, failure} = Verdict.check(false, :net_covers_fees)
      assert Exception.message(failure) =~ "check `net_covers_fees` returned `false`;"
    end

    test "{:fail, reason} is the returned form of fail!/2: the same exception" do
      raised =
        try do
          PropertyDamage.fail!("net below fees")
        rescue
          e in CheckFailed -> e
        end

      assert Verdict.check({:fail, "net below fees"}, :net_covers_fees) == {:fail, raised}
    end
  end
end
