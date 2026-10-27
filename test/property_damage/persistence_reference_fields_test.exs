defmodule PropertyDamage.PersistenceReferenceFieldsTest do
  # A saved report keeps the reference trace, the reference state at the
  # failing boundary and the shrink stop, and a version-15 file saved before
  # those fields existed still loads, with each of them nil (DR-055).
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Persistence, RunTrace}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.TmpPath

  @new_fields [:reference_trace, :reference_state_at_failure, :shrink_stop]

  # The file was saved by the format-15 code that predates the fields, from a
  # run of two PayAdapter targets "a" and "b" compared on this projection.
  @fixture Path.expand("../support/fixtures/persistence/v15_without_reference_fields.pd", __DIR__)

  @saved_projection_source """
  defmodule PropertyDamage.Test.SavedV15.Ledger do
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Settled}

    @impl true
    def init, do: %{unsettled: %{}, settled: 0, by: nil}

    @impl true
    def apply(s, %Paid{n: n, amount: a, by: by}), do: %{s | unsettled: Map.put(s.unsettled, n, a), by: by}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
    def apply(s, _), do: s

    @compare every: 1
    def totals(s, _root) do
      if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
    end
  end
  """

  # Loading decodes only atoms that exist, so the saved run's projection and
  # model are defined before the file is read.
  setup_all do
    projection = PropertyDamage.Test.SavedV15.Ledger

    unless Code.ensure_loaded?(projection) do
      {:ok, [^projection | _]} = Compare.compile(@saved_projection_source)
    end

    model = PropertyDamage.Test.SavedV15.Model

    unless Code.ensure_loaded?(model) do
      Compare.define_model!(model, [projection])
    end

    # Modules load on first use, so an atom the file holds (a module, a
    # struct field) may not exist yet in this VM: load every module first.
    Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)

    :ok
  end

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

    assert {:error, %FailureReport{kind: :diverged} = report} = R.run(model, targets)

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

  test "a version-15 file saved before the fields existed loads with each of them nil" do
    # A pre-field file loads without drift; a version warning is fine.
    assert <<"PD", 15, _rest::binary>> = File.read!(@fixture)

    {report, warnings} = load(@fixture)
    refute drift?(warnings), "unexpected drift: #{inspect(warnings)}"

    for field <- @new_fields do
      assert Map.has_key?(report, field), "the loaded report lacks #{inspect(field)}"
      assert Map.fetch!(report, field) == nil
    end

    assert report.kind == :diverged
    assert report.variant == %{index: 1, name: "b"}
    assert %RunTrace{} = report.trace
  end

  test "a version-15 divergence saved before the wait fields loads with each of them nil" do
    # The divergence in the file predates waited_ms and within_ms.
    {report, _warnings} = load(@fixture)
    assert %Failure.Divergence{} = divergence = report.failure_reason.type

    for field <- [:waited_ms, :within_ms] do
      assert Map.has_key?(divergence, field), "the loaded divergence lacks #{inspect(field)}"
      assert Map.fetch!(divergence, field) == nil
    end
  end
end
