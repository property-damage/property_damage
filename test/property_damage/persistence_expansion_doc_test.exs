defmodule PropertyDamage.PersistenceExpansionDocTest do
  # A saved report keeps the doc of each realized choice, and a version-15
  # file saved before an entry could carry a doc still loads: each choice in
  # its trace has the doc key, set to nil.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.{Expansion, FailureReport, Persistence}
  alias PropertyDamage.Test.Expansion, as: X
  alias PropertyDamage.Test.Expansion.{Authorize, Capture, Pay, StaticModel}
  alias PropertyDamage.Test.TmpPath

  # The files were written at bf16b8d, before an entry could carry a doc.
  @fixtures Path.expand("../support/fixtures/persistence", __DIR__)
  @report Path.join(@fixtures, "v15_expansion_without_doc.pd")
  @trace Path.join(@fixtures, "v15_expansion_trace_without_doc.pdtrace")

  @two_steps "authorize, then capture"

  # Loading decodes only atoms that exist, so every module is loaded first.
  setup_all do
    Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)
    :ok
  end

  defp loaded({:ok, value}), do: {value, []}
  defp loaded({:ok, value, warnings}), do: {value, warnings}

  defp expansion_choices(%{expansion: expansion}), do: expansion |> Map.values() |> List.flatten()

  defp assert_no_drift(warnings) do
    for warning <- warnings do
      refute inspect(warning) =~ ~r/expansion|doc|missing/i,
             "unexpected warning: #{inspect(warning)}"
    end
  end

  describe "a version-15 report saved before the field" do
    test "loads, and each choice of its trace has the doc key set to nil" do
      assert <<"PD", 15, _rest::binary>> = File.read!(@report)

      {report, warnings} = loaded(Persistence.load(@report))
      assert_no_drift(warnings)

      choices = expansion_choices(report.trace)
      assert [_ | _] = choices

      for choice <- choices do
        assert Map.has_key?(choice, :doc)
        assert Map.fetch!(choice, :doc) == nil
      end
    end

    test "realizes its carried choices again, each with the doc key" do
      {report, _warnings} = loaded(Persistence.load(@report))
      traced = report.trace.expansion["solo"]
      assert Enum.any?(traced, &(&1.index == 1))

      carried = Expansion.carried(StaticModel, FailureReport.shrunk_sequence(report), traced)

      assert Enum.map(carried.choices, &{&1.root_id, &1.entry}) ==
               Enum.map(traced, &{&1.root_id, &1.entry})

      for choice <- carried.choices do
        assert Map.has_key?(choice, :doc)
        assert Map.fetch!(choice, :doc) == nil
      end
    end
  end

  describe "a version-15 trace saved before the field" do
    test "loads, and each choice has the doc key set to nil" do
      assert <<"PD", 15, _rest::binary>> = File.read!(@trace)

      {trace, warnings} = loaded(Persistence.load_trace(@trace))
      assert_no_drift(warnings)

      choices = expansion_choices(trace)
      assert [_ | _] = choices

      for choice <- choices do
        assert Map.has_key?(choice, :doc)
        assert Map.fetch!(choice, :doc) == nil
      end
    end
  end

  test "a report of a model with documented entries saves and loads with its docs" do
    model =
      X.define_model!(Module.concat(ExpansionDocPersistence, Model),
        expansions: [
          {Pay,
           fn %Pay{amount: a} = pay, _state ->
             [
               {[pay], weight: 3},
               {[
                  {Authorize, overrides: %{amount: a}},
                  {Capture,
                   overrides: fn _state, [%{events: [%X.Authorized{id: id}]}] ->
                     %{authorization_id: id, amount: a}
                   end}
                ], doc: @two_steps}
             ]
           end}
        ]
      )

    report =
      Enum.find_value(1..200, fn seed ->
        target = X.target("solo", start_recorder(), nil, %{fail: %{Capture => :error}})

        case X.run(model, [target], seed: seed, max_commands: 4, shrink: true) do
          {:error, %FailureReport{} = report} -> report
          {:ok, _stats} -> nil
        end
      end) || flunk("no seed in 1..200 fails")

    dir = TmpPath.unique("pd_expansion_doc")
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:ok, path} = Persistence.save(report, dir)
    {loaded, _warnings} = loaded(Persistence.load(path))

    docs = fn report ->
      for choice <- report.trace.expansion["solo"], do: Map.fetch!(choice, :doc)
    end

    assert docs.(loaded) == docs.(report)
    assert @two_steps in docs.(loaded)
  end
end
