defmodule PropertyDamageTest do
  use ExUnit.Case
  doctest PropertyDamage

  describe "module" do
    test "defines moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(PropertyDamage)

      assert moduledoc =~ "stateful property-based testing"
    end
  end
end
