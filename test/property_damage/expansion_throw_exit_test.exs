defmodule PropertyDamage.ExpansionThrowExitTest do
  # A throw or an exit from user code that an expansion runs (an expansion
  # function, a leaf's `overrides:` function, a leaf's generator) is the same
  # generation error a raise is: an `ArgumentError` whose message names the
  # kind, `{:throw, value}` or `{:exit, reason}`. In a shrink candidate it makes
  # the candidate invalid, so the run still returns its report.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Expansion
  alias PropertyDamage.Test.Expansion.{Credit, Pay}
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.Refund

  defmodule ThrowingLeaf do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: throw(:no_leaf_today)
  end

  @doc false
  # Splits a Refund of at least 2 into two credits; shrinking halves an amount
  # to 1 and 0, where the function throws.
  def throwing(%Refund{tag: tag, amount: n} = refund, _state) when n >= 2 do
    a = div(n, 2)

    [
      [refund],
      [
        {X.Credit, overrides: %{tag: tag, amount: a, part: 0}},
        {X.Credit, overrides: %{tag: tag, amount: n - a, part: 1}}
      ]
    ]
  end

  def throwing(%Refund{}, _state), do: throw(:outside_the_clauses)

  defp model!(name, opts) do
    module = Module.concat(ExpansionThrowExit, name)
    if Code.ensure_loaded?(module), do: module, else: Expansion.define_model!(module, opts)
  end

  test "an expansion function that throws on a shrink candidate leaves the report" do
    module = ExpansionThrowExit.Throwing

    model =
      if Code.ensure_loaded?(module),
        do: module,
        else: X.define_model!(module, expansions: [{Refund, &__MODULE__.throwing/2}])

    targets = [X.target("alpha", nil), X.target("beta", nil, %{bug: :credit})]

    assert {:error, %FailureReport{variant: %{name: "beta"}}} =
             PropertyDamage.run(
               model: model,
               targets: targets,
               compare: [converge_within: 30],
               max_runs: 1,
               max_commands: 12,
               validate: false,
               seed: 2,
               shrink: true
             )
  end

  test "a leaf's overrides: function that exits is a generation error naming the exit" do
    model =
      model!(ExitingOverrides,
        expansions: [
          {Pay, fn _pay, _state -> [[{Credit, overrides: fn _state -> exit(:no_amount) end}]] end}
        ]
      )

    message =
      Expansion.error_message(fn -> Expansion.run(model, [Expansion.target("a", nil)]) end)

    assert message =~ "Pay[0]"
    assert message =~ "{:exit, :no_amount}"
  end

  test "a leaf generator that throws is a generation error naming the throw" do
    model =
      model!(ThrowingGenerator, expansions: [{Pay, fn _pay, _state -> [[ThrowingLeaf]] end}])

    message =
      Expansion.error_message(fn -> Expansion.run(model, [Expansion.target("a", nil)]) end)

    assert message =~ "Pay[0]"
    assert message =~ "{:throw, :no_leaf_today}"
  end
end
