defmodule PropertyDamage.Model.Projection.CheckTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model.Projection.Check
  alias PropertyDamage.Test.CheckKindMatrix

  describe "kind derivation in the projection macros" do
    test "every declared check carries the kind its type and trigger imply" do
      checks = CheckKindMatrix.Checks.__checks__()

      assert Enum.all?(checks, &match?(%Check{}, &1))

      for check <- checks do
        expected =
          case check do
            %{type: :polling} -> :eventually
            %{trigger: %{type: :at}} -> :phase
            %{type: :synchronous} -> :step
          end

        assert check.kind == expected, "#{check.name}: #{inspect(check.kind)}"
      end
    end

    test "the fixture covers all three kinds" do
      kinds = for c <- CheckKindMatrix.Checks.__checks__(), uniq: true, do: c.kind
      assert Enum.sort(kinds) == [:eventually, :phase, :step]
    end
  end

  describe "new/1" do
    test "derives kind from type and trigger" do
      base = %{name: :x, function_name: :assert_x}

      assert %Check{kind: :step} =
               Check.new(Map.merge(base, %{type: :synchronous, trigger: %{type: :every_step}}))

      assert %Check{kind: :phase} =
               Check.new(
                 Map.merge(base, %{type: :synchronous, trigger: %{type: :at, phase: :startup}})
               )

      assert %Check{kind: :eventually} = Check.new(Map.merge(base, %{type: :polling}))
    end

    test "rejects a field the struct does not declare" do
      assert_raise KeyError, fn -> Check.new(%{type: :polling, bogus: 1}) end
    end
  end
end
