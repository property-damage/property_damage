defmodule PropertyDamage.ExpansionExportBindingsTest.Http do
  @moduledoc false
  # The HTTP view the exporters read: every command posts its id fields.
  alias PropertyDamage.Export.HTTPSpec

  def http_spec(command, _ctx) do
    name = command.__struct__ |> Module.split() |> List.last() |> String.downcase()

    %HTTPSpec{
      method: :post,
      path: "/#{name}",
      body: Map.take(command, [:account_id, :authorization_id])
    }
  end
end

defmodule PropertyDamage.ExpansionExportBindingsTest do
  # A generated script binds each external value from the response of the
  # step that produced it in the reference target's run. A root's value that
  # one of its leaves produced (the root ran as an expansion) is bound after
  # that leaf's step; a root's own value is bound after the root's step, even
  # when an earlier root ran as several leaves and moved the step numbers.
  use ExUnit.Case, async: false

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.ExpansionExportBindingsTest.Http
  alias PropertyDamage.Export
  alias PropertyDamage.Export.StepPlan
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Expansion

  alias PropertyDamage.Test.Expansion.{
    Authorize,
    Capture,
    Confirm,
    Open,
    Pay,
    Reserve,
    Use
  }

  defp model_once!(name, opts) do
    module = Module.concat(ExpansionExportBindings, name)
    if Code.ensure_loaded?(module), do: module, else: Expansion.define_model!(module, opts)
  end

  defp use_command,
    do: {Use, when: &(&1.accounts != []), overrides: &%{account_id: List.last(&1.accounts)}}

  defp failing_report(model, failed_at) do
    target = Expansion.target("solo", start_recorder(), :random, %{fail: %{Use => :error}})

    assert {:error, %FailureReport{} = report} =
             Expansion.run(model, [target], seed: 7, max_runs: 1, max_commands: 3, shrink: false)

    assert report.failed_at_index == failed_at
    report
  end

  defp step!(plan, module) do
    [step | _] = Enum.filter(plan, &(&1.command.__struct__ == module))
    step
  end

  # The curl section (title line and body) that extracts `var`.
  defp extracting_section(script, var) do
    script
    |> String.split("=== Step ")
    |> Enum.drop(1)
    |> Enum.find(&(&1 =~ "#{var}=$("))
  end

  test "a root's value produced by a leaf is bound after that leaf's step" do
    model =
      model_once!(LeafProducer,
        commands: [{Open, when: &(&1.accounts == [])}, use_command()],
        expansions: [{Open, fn _open, _state -> [[Reserve, Confirm]] end}]
      )

    report = failing_report(model, 1)

    assert report |> Map.fetch!(:expansions) |> Map.fetch!("solo") |> Enum.map(& &1.leaves) ==
             [[Reserve, Confirm], [Use]]

    plan = StepPlan.build(report, Http)

    assert step!(plan, Reserve).producer_bindings == []
    assert [{[:id], var}] = step!(plan, Confirm).producer_bindings
    assert step!(plan, Use).resolved_body.account_id == %StepPlan.Var{name: var}

    script = Export.to_script(report, :curl, base_url: "http://localhost:4000", adapter: Http)
    assert extracting_section(script, var) =~ ~r/^\d+: Confirm/
  end

  test "a root's own value is bound after the root's step when an earlier root ran as leaves" do
    rewrite = fn %Pay{} = pay, state -> Enum.drop(Expansion.pay_expansions(pay, state), 1) end

    model =
      model_once!(ShiftedProducer,
        commands: [
          {Pay, when: &(&1.total == 0)},
          {Open, when: &(&1.total > 0 and &1.accounts == [])},
          use_command()
        ],
        expansions: [{Pay, rewrite}]
      )

    report = failing_report(model, 2)

    assert report |> Map.fetch!(:expansions) |> Map.fetch!("solo") |> Enum.map(& &1.leaves) ==
             [[Authorize, Capture], [Open], [Use]]

    plan = StepPlan.build(report, Http)

    assert [{[:id], account}] = step!(plan, Open).producer_bindings
    assert step!(plan, Capture).producer_bindings == []
    assert step!(plan, Use).resolved_body.account_id == %StepPlan.Var{name: account}

    # The leaf-to-leaf value: Capture uses the id its sibling Authorize answered.
    assert [{[:id], authorization}] = step!(plan, Authorize).producer_bindings

    assert step!(plan, Capture).resolved_body.authorization_id == %StepPlan.Var{
             name: authorization
           }

    assert authorization != account

    script = Export.to_script(report, :curl, base_url: "http://localhost:4000", adapter: Http)
    assert extracting_section(script, account) =~ ~r/^\d+: Open/
    assert extracting_section(script, authorization) =~ ~r/^\d+: Authorize/
  end
end
