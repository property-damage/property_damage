defmodule PropertyDamage.SuggestionsExampleCodeTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Suggestions
  alias PropertyDamage.SuggestionsFixtures, as: Fixtures

  @pattern_kinds ~w(non_negative_check currency_consistency cross_event_currency
                    reference_exists valid_status_transition event_coverage)a

  defp suggestions_with_code do
    Fixtures.FullModel
    |> Suggestions.analyze()
    |> Map.fetch!(:suggestions)
    |> Enum.filter(& &1.example_code)
  end

  test "the fixture model yields example code for every pattern kind" do
    kinds = suggestions_with_code() |> Enum.map(& &1.type) |> Enum.uniq()

    for kind <- @pattern_kinds, do: assert(kind in kinds, "no suggestion of kind #{kind}")
  end

  test "example code declares each check with an @check attribute" do
    for suggestion <- suggestions_with_code() do
      code = suggestion.example_code
      ast = Code.string_to_quoted!(code)

      assert code =~ "@check", "#{suggestion.type} example has no @check"
      refute code =~ "check(:always)", "#{suggestion.type} example uses the removed syntax"
      refute code =~ "def check(", "#{suggestion.type} example uses the removed syntax"
      assert ast != nil
    end
  end

  test "example code compiles inside a projection" do
    for {suggestion, index} <- Enum.with_index(suggestions_with_code()) do
      source = """
      defmodule PropertyDamage.SuggestionsExampleCodeTest.Sample#{index} do
        use PropertyDamage.Model.Projection

        @impl true
        def init, do: %{entities: %{}, operations: [], orders: %{}, accounts: %{}}

        @impl true
        def apply(state, _event), do: state

      #{suggestion.example_code}
      end
      """

      assert [{_module, _binary}] = Code.compile_string(source),
             "#{suggestion.type} example does not compile"
    end
  end
end
