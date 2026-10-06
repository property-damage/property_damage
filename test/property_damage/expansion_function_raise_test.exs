defmodule PropertyDamage.ExpansionFunctionRaiseTest do
  # An expansion function that raises is a generation error: an
  # `ArgumentError` naming the root module, the root index and what the
  # function raised. In the run that finds a failure it stops the run before
  # any target is set up. In a shrink candidate it makes the candidate invalid,
  # so a function whose clauses cover only the roots the generator produces
  # (and not the simplified roots shrinking tries) still returns the report.
  use ExUnit.Case, async: false

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Credit, Refund}

  @sink :expansion_function_raise_sink

  @doc false
  # Refund amounts are generated from 2..1000, so the guard holds for every
  # generated root; shrinking halves an amount to 1 and 0, where no clause
  # matches.
  def guarded(%Refund{amount: n} = refund, state) do
    if pid = Process.whereis(@sink), do: send(pid, {:amount, n})
    split(refund, state)
  end

  defp split(%Refund{tag: tag, amount: n} = refund, _state) when n >= 2 do
    a = div(n, 2)

    [
      [refund],
      [
        {Credit, overrides: %{tag: tag, amount: a, part: 0}},
        {Credit, overrides: %{tag: tag, amount: n - a, part: 1}}
      ]
    ]
  end

  defp model_once!(name, opts) do
    module = Module.concat(ExpansionFunctionRaise, name)
    if Code.ensure_loaded?(module), do: module, else: X.define_model!(module, opts)
  end

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 12,
          validate: false
        ],
        extra
      )
    )
  end

  defp targets(recorder),
    do: [X.target("alpha", recorder), X.target("beta", recorder, %{bug: :credit})]

  test "a shrink candidate outside the function's clauses is invalid, and the run returns the report" do
    Process.register(self(), @sink)
    model = model_once!(Guarded, expansions: [{Refund, &__MODULE__.guarded/2}])

    assert {:error, %FailureReport{} = found} =
             run(model, targets(nil), seed: 2, shrink: false)

    assert {:error, %FailureReport{} = report} = run(model, targets(nil), seed: 2, shrink: true)

    # Shrinking asked the function about a Refund the generator never makes.
    amounts = for {:amount, n} <- drain(), do: n
    assert Enum.any?(amounts, &(&1 < 2))

    assert {report.kind, report.variant} == {found.kind, found.variant}
    assert report.variant == %{index: 1, name: "beta"}

    at_failure =
      report
      |> Map.fetch!(:expansions)
      |> Map.fetch!("beta")
      |> Enum.find(&(&1.root == report.failed_at_index))

    assert %{entry: "Refund[1]", leaves: [Credit, Credit]} = at_failure
  end

  test "a function that raises while the run generates is a generation error naming the root" do
    model =
      model_once!(Raising,
        expansions: [{Refund, fn %Refund{}, _state -> raise "no expansion today" end}]
      )

    seed =
      X.find_seed(model, 12, 1..2_000, &Enum.any?(&1, fn root -> match?(%Refund{}, root) end)) ||
        flunk("no seed in 1..2000 generates a Refund root")

    index =
      model |> X.roots(seed, 12) |> Enum.find_index(&match?(%Refund{}, &1))

    recorder = start_recorder()

    error =
      assert_raise ArgumentError, fn ->
        run(model, targets(recorder), seed: seed, shrink: false)
      end

    assert error.message =~ inspect(Refund)
    assert error.message =~ "root #{index}"
    assert error.message =~ "no expansion today"
    assert recorder |> recorded() |> Enum.filter(&match?({:setup, _}, &1)) == []
  end

  defp drain do
    receive do
      message -> [message | drain()]
    after
      0 -> []
    end
  end
end
