defmodule PropertyDamage.PersistenceReferenceFieldsTest do
  # A saved report keeps the reference trace, the reference state at the
  # failing boundary and the shrink stop (DR-055).
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Persistence, RunTrace}
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.TmpPath

  @new_fields [:reference_trace, :reference_state_at_failure, :shrink_stop]

  defp load(path) do
    case Persistence.load(path) do
      {:ok, report} -> {report, []}
      {:ok, report, warnings} -> {report, warnings}
    end
  end

  defp drift?(warnings), do: Enum.any?(warnings, &match?({:struct_shape_drift, _, _}, &1))

  test "a divergence report saves and loads equal, its reference trace and state included" do
    # Persistence keeps the new fields of a :diverged report.
    model = R.pay_model(Module.concat(__MODULE__, LedgerModel), R.Ledger)
    targets = [R.pay_target("a"), R.pay_target("b", %{at: %{1 => {:sync, 1}}})]

    assert {:error, %FailureReport{report_kind: :diverged} = report} = R.run(model, targets)

    dir = TmpPath.unique("pd_reference_fields")
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:ok, path} = Persistence.save(report, dir)

    {loaded, warnings} = load(path)
    refute drift?(warnings), "unexpected warnings: #{inspect(warnings)}"
    assert loaded == report

    assert %RunTrace{} = R.field(report, :reference_trace)
    assert %{R.Ledger => %{by: "a"}} = R.field(report, :reference_state_at_failure)
    assert R.field(report, :shrink_stop) == :done

    for field <- @new_fields do
      assert Map.fetch!(loaded, field) == Map.fetch!(report, field)
    end
  end
end
