defmodule PropertyDamage.PersistenceExpansionDocTest do
  # A saved report keeps the doc of each realized choice.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.{FailureReport, Persistence}
  alias PropertyDamage.Test.Expansion, as: X
  alias PropertyDamage.Test.Expansion.{Authorize, Capture, Pay}
  alias PropertyDamage.Test.TmpPath

  @two_steps "authorize, then capture"

  # Loading decodes only atoms that exist, so every module is loaded first.
  setup_all do
    Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)
    :ok
  end

  defp loaded({:ok, value}), do: {value, []}
  defp loaded({:ok, value, warnings}), do: {value, warnings}

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
