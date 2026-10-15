defmodule PropertyDamage.ExportShrunkBindingsTest.Http do
  @moduledoc false
  alias PropertyDamage.Export.HTTPSpec

  def http_spec(command, _ctx) do
    name = command.__struct__ |> Module.split() |> List.last() |> String.downcase()
    %HTTPSpec{method: :post, path: "/#{name}", body: Map.take(command, [:account_id])}
  end
end

defmodule PropertyDamage.ExportShrunkBindingsTest do
  # A shrunk sequence can drop a root that came before the producer of an
  # external() value. For a model without expansions/0, an export binds the
  # value after the step of the command that produces it in the shrunk
  # sequence, never after the step that held the producer's old position.
  use ExUnit.Case, async: false

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.Export.StepPlan
  alias PropertyDamage.ExportShrunkBindingsTest.Http
  alias PropertyDamage.{FailureReport, Sequence}
  alias PropertyDamage.Test.Expansion
  alias PropertyDamage.Test.Expansion.{Open, Use}

  defp run(model, seed, shrink) do
    target = Expansion.target("solo", start_recorder(), nil, %{fail: %{Use => :error}})
    Expansion.run(model, [target], seed: seed, max_runs: 1, max_commands: 3, shrink: shrink)
  end

  test "a shrunk export binds the consumed value after the step that produces it" do
    model =
      Expansion.define_model!(PropertyDamage.ExportShrunkBindingsTest.Model,
        commands: [
          {Open, when: &(length(&1.accounts) < 3)},
          {Use, when: &(&1.accounts != []), overrides: &%{account_id: List.last(&1.accounts)}}
        ]
      )

    # A seed whose run is [Open, Open, Use] failing at Use: shrinking drops
    # the first Open, so the producer of Use's value moves from index 1 to 0.
    seed =
      Enum.find(1..200, fn seed ->
        case run(model, seed, false) do
          {:error, %FailureReport{failed_at_index: 2} = report} ->
            report.original_sequence |> Sequence.to_list() |> Enum.map(& &1.__struct__) ==
              [Open, Open, Use]

          _other ->
            false
        end
      end) || flunk("no seed in 1..200 gives [Open, Open, Use] failing at Use")

    assert {:error, %FailureReport{} = shrunk} = run(model, seed, true)

    assert shrunk
           |> FailureReport.shrunk_sequence()
           |> Sequence.to_list()
           |> Enum.map(& &1.__struct__) ==
             [Open, Use]

    [open, use] = StepPlan.build(shrunk, Http)
    assert %StepPlan.Var{name: var} = use.resolved_body.account_id
    assert {[:id], var} in open.producer_bindings
    assert use.producer_bindings == []
  end
end
