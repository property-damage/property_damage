defmodule PropertyDamage.DocsFetchTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Docs
  alias PropertyDamage.Test.DocsFixtures
  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  # The module as `Code.fetch_docs/1` describes it, translated by the contract:
  # `:hidden` reads false, `:none` reads nil, a function line is the annotation's.
  defp expected_from_chunk(module) do
    {:docs_v1, _anno, _lang, _format, moduledoc, _meta, entries} = Code.fetch_docs(module)

    functions =
      for {{:function, name, arity}, anno, _signature, doc, _meta} <- entries, into: %{} do
        {{name, arity}, %{doc: Helpers.translate_doc(doc), line: :erl_anno.line(anno)}}
      end

    source =
      case module.module_info(:compile)[:source] do
        nil -> nil
        path -> to_string(path)
      end

    %{moduledoc: Helpers.translate_doc(moduledoc), file: source, functions: functions}
  end

  describe "a module declared with a macro" do
    test "fetch answers the map the module captured at compile time" do
      for module <- [DocsFixtures.Model, DocsFixtures.Projection, DocsFixtures.Command] do
        assert Code.ensure_loaded?(module)
        assert function_exported?(module, :__pd_docs__, 0)
        assert Docs.fetch(module) == {:ok, module.__pd_docs__()}
      end
    end
  end

  describe "a module with a docs chunk and no macro" do
    test "fetch translates Code.fetch_docs for a module of the library" do
      module = PropertyDamage.Model.Projection.Liveness
      assert Code.ensure_loaded?(module)
      refute function_exported?(module, :__pd_docs__, 0)

      assert {:ok, docs} = Docs.fetch(module)
      assert docs == expected_from_chunk(module)

      # Hand-checked entries.
      assert String.starts_with?(docs.moduledoc, "Projection that tracks pending operations")
      assert Path.basename(docs.file) == "liveness.ex"

      assert String.starts_with?(
               docs.functions[{:check_liveness, 2}].doc,
               "Check for stuck operations."
             )

      assert String.starts_with?(
               docs.functions[{:pending_count, 1}].doc,
               "Get count of currently pending operations."
             )

      assert docs.functions[{:__checks__, 0}].doc == false
      assert docs.functions[{:check, 3}].doc == false
    end

    test "fetch reads a hidden moduledoc as false and a missing one as nil" do
      for {module, moduledoc} <- [
            {DocsFixtures.PlainHidden, false},
            {DocsFixtures.PlainBare, nil}
          ] do
        assert Code.ensure_loaded?(module)
        refute function_exported?(module, :__pd_docs__, 0)

        assert {:ok, docs} = Docs.fetch(module)
        assert docs.moduledoc == moduledoc
        assert docs == expected_from_chunk(module)
      end

      assert {:ok, hidden} = Docs.fetch(DocsFixtures.PlainHidden)
      assert hidden.functions[{:shown, 0}].doc == "Documented in a hidden module."
      assert hidden.functions[{:hidden, 0}].doc == false

      assert {:ok, bare} = Docs.fetch(DocsFixtures.PlainBare)
      assert bare.functions[{:undocumented, 0}].doc == nil
    end
  end

  describe "a module with no docs at all" do
    test "a bare behaviour declaration has no captured docs and nothing to translate" do
      suffix = Helpers.suffix()
      module = Module.concat(["PropertyDamage.Test.DocsBare#{suffix}"])
      file = TmpPath.unique("docs_bare") <> ".exs"

      source = """
      defmodule #{inspect(module)} do
        @moduledoc "A model declared by hand."
        @behaviour PropertyDamage.Model

        @doc "No commands."
        def commands, do: []
        def command_sequence_projection, do: nil
      end
      """

      modules = Helpers.compile(source, file)
      on_exit(fn -> Helpers.purge(modules) end)

      assert Code.ensure_loaded?(module)
      refute function_exported?(module, :__pd_docs__, 0)
      assert Code.fetch_docs(module) == {:error, :module_not_found}
      assert Docs.fetch(module) == :unavailable
    end

    test "an atom that names no module is unavailable" do
      assert Docs.fetch(:"Elixir.PropertyDamage.Test.NoSuchModule#{Helpers.suffix()}") ==
               :unavailable
    end
  end

  describe "the beam of a declared module" do
    test "holds the moduledoc but never the source text" do
      module = DocsFixtures.Sentinel
      assert {^module, binary, _path} = :code.get_object_code(module)

      text = Helpers.beam_text(binary)

      # Positive control: the moduledoc is kept in the beam by design, so the
      # search must find it.
      assert text =~ "MODULEDOC_SENTINEL_5f0c1d"
      assert {:ok, %{moduledoc: moduledoc}} = Docs.fetch(module)
      assert moduledoc =~ "MODULEDOC_SENTINEL_5f0c1d"

      refute text =~ "COMMENT_SENTINEL_9b7e2a"
    end
  end
end
