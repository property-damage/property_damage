defmodule PropertyDamage.PersistenceExportJsonReferenceTest do
  # `Persistence.export_json/1` carries the reference side of a comparison
  # failure: the reference trace, the reference projection state at the
  # failing boundary and why the shrinker stopped.
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Persistence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ReferenceReport, as: R

  defp diverged_report do
    model = R.pay_model(Module.concat(__MODULE__, LedgerModel), R.Ledger)
    targets = [R.pay_target("a"), R.pay_target("b", %{at: %{1 => {:sync, 1}}})]
    assert {:error, %FailureReport{kind: :diverged} = report} = R.run(model, targets)
    report
  end

  test "the export of a divergence report carries the reference trace, state and shrink stop" do
    report = diverged_report()
    exported = report |> Persistence.export_json() |> Jason.decode!()
    formatted = report |> Formatter.format(:json) |> Jason.decode!()

    assert %{"target" => "a", "event_log" => [_ | _]} = exported["reference_trace"]
    assert exported["reference_trace"] == formatted["reference_trace"]

    assert %{"Ledger" => %{"by" => "a"}} =
             exported["reference_state_at_failure"]

    assert exported["reference_state_at_failure"] == formatted["reference_projections"]
    assert exported["shrink_stop"] == "done"
    assert exported["shrink_stop"] == formatted["shrinking"]["stop"]
  end

  test "the export of a report that is not a comparison failure carries them as null" do
    report = %{
      diverged_report()
      | reference_trace: nil,
        reference_state_at_failure: nil,
        shrink_stop: nil
    }

    exported = report |> Persistence.export_json() |> Jason.decode!()

    for key <- ["reference_trace", "reference_state_at_failure", "shrink_stop"] do
      assert Map.has_key?(exported, key), "the export lacks #{key}"
      assert Map.fetch!(exported, key) == nil
    end
  end
end
