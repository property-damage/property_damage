defmodule PropertyDamage.LoadFailureSpecTest do
  use ExUnit.Case, async: true

  test "load_failure/1 spec includes the three-tuple with version warnings" do
    {:ok, specs} = Code.Typespec.fetch_specs(PropertyDamage)
    [{:type, _, :fun, [_args, return]}] = for {{:load_failure, 1}, [clause]} <- specs, do: clause

    members =
      case return do
        {:type, _, :union, members} -> members
        other -> [other]
      end

    assert Enum.any?(members, &match?({:type, _, :tuple, [{:atom, _, :ok}, _, _]}, &1))
  end
end
