defmodule PropertyDamage.DocsCaptureTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.DocsFixtures
  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  @fixture_file Path.expand("../support/docs_fixtures.ex", __DIR__)
  @markers @fixture_file |> File.read!() |> Helpers.marker_lines()

  defp pd_docs(module), do: module.__pd_docs__()

  defp line(id), do: Map.fetch!(@markers, id)

  defp entry(doc, id), do: %{doc: doc, line: line(id)}

  describe "the map of a declared module" do
    test "a model answers moduledoc, file and functions and nothing else" do
      docs = pd_docs(DocsFixtures.Model)

      assert docs |> Map.keys() |> Enum.sort() == [:file, :functions, :moduledoc]
      assert docs.moduledoc == "Model fixture for doc capture.\n"
      assert Path.type(docs.file) == :absolute
      assert docs.file == @fixture_file
    end

    test "a model lists the functions its source writes with their docs and lines" do
      %{functions: functions} = pd_docs(DocsFixtures.Model)

      expected = %{
        {:commands, 0} => entry(false, "model.commands"),
        {:command_sequence_projection, 0} =>
          entry("Names the projection.", "model.command_sequence_projection"),
        {:hidden_note, 0} => entry(false, "model.hidden_note"),
        {:undocumented_note, 0} => entry(nil, "model.undocumented_note"),
        {:classify, 1} => entry("Classifies by sign.", "model.classify"),
        {:headed, 1} => entry("Head doc.", "model.headed")
      }

      assert Map.take(functions, Map.keys(expected)) == expected
    end

    test "a projection answers its moduledoc, file and functions" do
      docs = pd_docs(DocsFixtures.Projection)

      assert docs |> Map.keys() |> Enum.sort() == [:file, :functions, :moduledoc]
      assert docs.file == @fixture_file
      assert Path.type(docs.file) == :absolute

      expected = %{
        {:init, 0} => entry(false, "projection.init"),
        {:apply, 2} => entry("Adds the amount of an event to the total.", "projection.apply"),
        {:assert_total_not_negative, 2} =>
          entry("Total never goes negative.", "projection.assert_total_not_negative"),
        {:hidden_total, 1} => entry(false, "projection.hidden_total"),
        {:plain_total, 1} => entry(nil, "projection.plain_total")
      }

      assert Map.take(docs.functions, Map.keys(expected)) == expected
    end

    test "a command answers its moduledoc, file and functions" do
      docs = pd_docs(DocsFixtures.Command)

      assert docs |> Map.keys() |> Enum.sort() == [:file, :functions, :moduledoc]
      assert docs.file == @fixture_file
      assert Path.type(docs.file) == :absolute

      expected = %{
        {:generator, 1} => entry("Generates an empty command.", "command.generator"),
        {:internal_note, 0} => entry(false, "command.internal_note"),
        {:plain_note, 0} => entry(nil, "command.plain_note")
      }

      assert Map.take(docs.functions, Map.keys(expected)) == expected
    end

    test "fetch answers the same map as the module" do
      for module <- [DocsFixtures.Model, DocsFixtures.Projection, DocsFixtures.Command] do
        assert PropertyDamage.Docs.fetch(module) == {:ok, pd_docs(module)}
      end
    end
  end

  describe "false and nil" do
    test "a moduledoc false reads false and a missing moduledoc reads nil" do
      assert pd_docs(DocsFixtures.Projection).moduledoc == false
      assert pd_docs(DocsFixtures.Command).moduledoc == nil
      assert is_binary(pd_docs(DocsFixtures.Model).moduledoc)
    end

    test "a doc false reads false and a missing doc reads nil" do
      %{functions: functions} = pd_docs(DocsFixtures.Model)

      assert functions[{:hidden_note, 0}].doc == false
      assert functions[{:undocumented_note, 0}].doc == nil
    end

    test "an impl without a doc reads false, as the compiler records it hidden" do
      assert pd_docs(DocsFixtures.Model).functions[{:commands, 0}].doc == false
      assert pd_docs(DocsFixtures.Projection).functions[{:init, 0}].doc == false
    end
  end

  describe "clauses, private functions and exclusions" do
    test "a multi-clause function reports the line of its first clause" do
      %{functions: functions} = pd_docs(DocsFixtures.Model)

      assert functions[{:classify, 1}].line == line("model.classify")
      assert functions[{:classify, 1}].line < line("model.headed")

      assert pd_docs(DocsFixtures.Projection).functions[{:apply, 2}].line ==
               line("projection.apply")
    end

    test "a bodiless head reports its own line" do
      assert pd_docs(DocsFixtures.Model).functions[{:headed, 1}] ==
               entry("Head doc.", "model.headed")
    end

    test "a private function is captured with nil when it has no doc" do
      %{functions: functions} = pd_docs(DocsFixtures.Model)

      assert %{doc: nil, line: line} = functions[{:quiet_helper, 0}]
      assert is_integer(line) and line > 0
    end

    test "macros and double-underscore names are left out" do
      %{functions: functions} = pd_docs(DocsFixtures.Model)

      names = functions |> Map.keys() |> Enum.map(&elem(&1, 0))

      refute :a_macro in names
      refute :"MACRO-a_macro" in names
      refute :__helper__ in names
      refute :__pd_docs__ in names
      refute Enum.any?(names, &String.starts_with?(Atom.to_string(&1), "__"))
    end

    test "a private function takes the doc attribute set before it" do
      suffix = Helpers.suffix()
      file = TmpPath.unique("docs_private") <> ".exs"

      source = """
      defmodule PropertyDamage.Test.DocsPrivate#{suffix} do
        @moduledoc "Private functions."
        use PropertyDamage.Model

        def commands, do: []
        def command_sequence_projection, do: nil

        defmacrop macro_made, do: :c

        def run, do: {with_doc(), without_doc(), macro_made()}

        @doc "A note on a private function."
        # line:with_doc
        defp with_doc, do: :a

        # line:without_doc
        defp without_doc, do: :b

        def __internal__, do: :internal
      end
      """

      modules = Helpers.compile(source, file)
      on_exit(fn -> Helpers.purge(modules) end)
      [{module, _binary}] = modules

      %{functions: functions} = pd_docs(module)
      markers = Helpers.marker_lines(source)

      assert functions[{:with_doc, 0}] ==
               %{doc: "A note on a private function.", line: markers["with_doc"]}

      assert functions[{:without_doc, 0}] == %{doc: nil, line: markers["without_doc"]}
      refute Map.has_key?(functions, {:macro_made, 0})
      refute Map.has_key?(functions, {:__internal__, 0})
    end
  end

  describe "a module that uses two macros" do
    test "compiles without a warning and answers one map holding its functions" do
      suffix = Helpers.suffix()
      file = TmpPath.unique("docs_both") <> ".exs"

      source = """
      defmodule PropertyDamage.Test.DocsBoth#{suffix} do
        @moduledoc "Both a model and a projection."
        use PropertyDamage.Model
        use PropertyDamage.Model.Projection

        # line:commands
        def commands, do: []
        def command_sequence_projection, do: __MODULE__

        # line:init
        def init, do: %{}

        @doc "Applies an event."
        # line:apply
        def apply(state, _event), do: state

        @doc "Counts nothing."
        # line:tally
        def tally(state), do: map_size(state)
      end
      """

      {modules, diagnostics} = Helpers.compile_with_diagnostics(source, file)
      on_exit(fn -> Helpers.purge(modules) end)
      [{module, _binary}] = modules

      assert diagnostics == []

      docs = pd_docs(module)
      assert docs |> Map.keys() |> Enum.sort() == [:file, :functions, :moduledoc]
      assert docs.moduledoc == "Both a model and a projection."
      assert docs.file == file

      markers = Helpers.marker_lines(source)

      assert docs.functions[{:apply, 2}] == %{doc: "Applies an event.", line: markers["apply"]}
      assert docs.functions[{:tally, 1}] == %{doc: "Counts nothing.", line: markers["tally"]}
      assert docs.functions[{:commands, 0}] == %{doc: nil, line: markers["commands"]}
      assert docs.functions[{:init, 0}] == %{doc: nil, line: markers["init"]}
    end
  end
end
