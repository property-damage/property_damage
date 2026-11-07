defmodule PropertyDamage.DocsHookOrderTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  # The map must hold every def and defp the beam holds. A function that a
  # `@before_compile` injects after `use` is captured like one written in the
  # body. A function written before `use` cannot be captured, so it is a
  # compile error.

  defp tmp_dir(prefix) do
    dir = TmpPath.unique(prefix)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp compile(source, file) do
    {modules, diagnostics} = Helpers.compile_with_diagnostics(source, file)
    on_exit(fn -> Helpers.purge(modules) end)
    {Map.new(modules), diagnostics}
  end

  # Each function of the beam with the doc and the line `Code.fetch_docs/1` reads.
  defp oracle_entries(beam) do
    assert {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(beam)

    for {{:function, name, arity}, anno, _signature, doc, _meta} <- entries, into: %{} do
      {{name, arity}, %{doc: Helpers.translate_doc(doc), line: :erl_anno.line(anno)}}
    end
  end

  describe "a function injected by a before_compile registered after use" do
    defp injected_source(prefix) do
      """
      defmodule #{prefix}.Injector do
        @moduledoc false

        defmacro __before_compile__(_env) do
          quote do
            @doc "Injected after use."
            def injected, do: :injected

            defp injected_private, do: :private
          end
        end
      end

      # line:Model
      defmodule #{prefix}.Model do
        @moduledoc "Model with an injected function."
        use PropertyDamage.Model
        @before_compile #{prefix}.Injector

        @impl true
        def commands, do: []

        @impl true
        def command_sequence_projection, do: nil
      end

      # line:Projection
      defmodule #{prefix}.Projection do
        @moduledoc "Projection with an injected function."
        use PropertyDamage.Model.Projection
        @before_compile #{prefix}.Injector

        @impl true
        def init, do: %{}

        @impl true
        def apply(state, _event), do: state
      end

      # line:Command
      defmodule #{prefix}.Command do
        @moduledoc "Command with an injected function."
        use PropertyDamage.Command
        @before_compile #{prefix}.Injector

        @impl true
        def generator(_overrides), do: StreamData.fixed_map([])
      end
      """
    end

    test "is captured with its doc and line in a model, a projection and a command" do
      prefix = "PropertyDamage.Test.DocsInjected#{Helpers.suffix()}"
      file = Path.join(tmp_dir("docs_injected"), "injected.exs")
      source = injected_source(prefix)
      {modules, diagnostics} = compile(source, file)
      markers = Helpers.marker_lines(source)

      assert diagnostics == []

      for kind <- [:Model, :Projection, :Command] do
        module = Module.concat([prefix, kind])
        assert Map.has_key?(modules, module)
        functions = module.__pd_docs__().functions

        assert functions[{:injected, 0}] ==
                 %{doc: "Injected after use.", line: markers[Atom.to_string(kind)]},
               inspect(module)

        assert %{doc: nil} = functions[{:injected_private, 0}], inspect(module)
      end
    end

    test "agrees with the docs chunk the compiler writes" do
      prefix = "PropertyDamage.Test.DocsInjectedOracle#{Helpers.suffix()}"
      dir = tmp_dir("docs_injected_oracle")

      modules =
        Helpers.compile_with_docs(injected_source(prefix), Path.join(dir, "injected.exs"))

      on_exit(fn -> Helpers.purge(modules) end)
      beams = Helpers.write_beams(modules, dir)

      for kind <- [:Model, :Projection, :Command] do
        module = Module.concat([prefix, kind])
        oracle = oracle_entries(beams[module])

        assert oracle[{:injected, 0}].doc == "Injected after use."
        assert module.__pd_docs__().functions[{:injected, 0}] == oracle[{:injected, 0}]
        assert module.__pd_docs__().moduledoc == "#{kind} with an injected function."
      end
    end
  end

  describe "a function written before use" do
    defp early_source(module, use_line) do
      """
      defmodule #{module} do
        @moduledoc false

        @doc "Written before use."
        def early, do: helper(:early)

        defp helper(value), do: value

        # line:use
        #{use_line}
      end
      """
    end

    test "is a compile error that names each such function" do
      for use_line <- [
            "use PropertyDamage.Model",
            "use PropertyDamage.Model.Projection",
            "use PropertyDamage.Command"
          ] do
        module = "PropertyDamage.Test.DocsEarly#{Helpers.suffix()}"
        file = Path.join(tmp_dir("docs_early"), "early.exs")
        source = early_source(module, use_line)

        error =
          assert_raise CompileError, fn ->
            Helpers.compile_with_diagnostics(source, file)
          end

        assert error.file == file
        assert error.line == Helpers.marker_lines(source)["use"]

        message = Exception.message(error)
        assert message =~ "early/0", use_line
        assert message =~ "helper/1", use_line
        assert message =~ use_line, use_line
      end
    end

    test "is no error for a second use of another macro after the first one's functions" do
      prefix = "PropertyDamage.Test.DocsSecondUse#{Helpers.suffix()}"
      file = Path.join(tmp_dir("docs_second_use"), "second_use.exs")

      source = """
      defmodule #{prefix}.ModelFirst do
        @moduledoc "A model, then a projection."
        use PropertyDamage.Model

        # line:model_first_commands
        def commands, do: []
        def command_sequence_projection, do: __MODULE__

        use PropertyDamage.Model.Projection

        def init, do: %{}
        def apply(state, _event), do: state
      end

      defmodule #{prefix}.ProjectionFirst do
        @moduledoc "A projection, then a model."
        use PropertyDamage.Model.Projection

        def init, do: %{}
        def apply(state, _event), do: state

        use PropertyDamage.Model

        # line:projection_first_commands
        def commands, do: []
        def command_sequence_projection, do: __MODULE__
      end
      """

      {modules, diagnostics} = compile(source, file)
      markers = Helpers.marker_lines(source)

      assert diagnostics == []

      for {kind, marker} <- [
            ModelFirst: "model_first_commands",
            ProjectionFirst: "projection_first_commands"
          ] do
        module = Module.concat([prefix, kind])
        assert Map.has_key?(modules, module)
        docs = module.__pd_docs__()

        assert docs.functions |> Map.keys() |> Enum.sort() ==
                 [apply: 2, command_sequence_projection: 0, commands: 0, init: 0]

        assert docs.functions[{:commands, 0}] == %{doc: nil, line: markers[marker]}
      end
    end
  end
end
