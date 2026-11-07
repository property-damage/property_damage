defmodule PropertyDamage.DocsScriptTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  defp tmp_dir(prefix) do
    dir = TmpPath.unique(prefix)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp compile!(source, file) do
    modules = Helpers.compile_with_docs(source, file)
    on_exit(fn -> Helpers.purge(modules) end)
    Map.new(modules)
  end

  describe "agreement with the compiler" do
    # Functions every module of the source writes itself, with the doc the
    # compiler is expected to attach.
    @written %{
      {:plain, 0} => "Plain doc.",
      {:hidden, 0} => false,
      {:bare, 0} => nil,
      {:later, 1} => "Doc on the second clause.",
      {:delegated, 1} => "Delegated with a doc.",
      {:delegated_bare, 1} => nil,
      {:with_default, 2} => "Has a default argument.",
      {:made_by_macro, 0} => "Made by a macro."
    }

    defp shared_body(host) do
      """
      @doc "Plain doc."
      def plain, do: 1

      @doc false
      def hidden, do: 2

      def bare, do: 3

      def later(0), do: :zero
      @doc "Doc on the second clause."
      def later(_), do: :other

      @doc "Delegated with a doc."
      defdelegate delegated(list), to: Enum, as: :count

      defdelegate delegated_bare(list), to: Enum, as: :count

      @doc "Has a default argument."
      def with_default(a, b \\\\ 1), do: a + b

      require #{host}

      @doc "Made by a macro."
      #{host}.make(:made_by_macro)
      """
    end

    defp differential_source(prefix) do
      host = "#{prefix}.Host"

      """
      defmodule #{host} do
        @moduledoc false

        defmacro make(name) do
          quote do
            def unquote(name)(), do: :made
          end
        end
      end

      defmodule #{prefix}.Model do
        @moduledoc "Differential model."
        use PropertyDamage.Model

        @impl true
        def commands, do: []

        @impl true
        def command_sequence_projection, do: #{prefix}.Projection

        #{shared_body(host)}
      end

      defmodule #{prefix}.Projection do
        @moduledoc "Differential projection."
        use PropertyDamage.Model.Projection

        @impl true
        def init, do: %{}

        @impl true
        def apply(state, _event), do: state

        @check every: 1
        def assert_fine(_state, _event), do: true

        #{shared_body(host)}
      end

      defmodule #{prefix}.Command do
        @moduledoc "Differential command."
        use PropertyDamage.Command

        @impl true
        def generator(_overrides), do: StreamData.fixed_map([])

        #{shared_body(host)}
      end
      """
    end

    test "each public function reads the doc that Code.fetch_docs reports for the beam" do
      prefix = "PropertyDamage.Test.DocsDiff#{Helpers.suffix()}"
      dir = tmp_dir("docs_diff")

      modules =
        Helpers.compile_with_docs(differential_source(prefix), Path.join(dir, "differential.exs"))

      on_exit(fn -> Helpers.purge(modules) end)
      beams = Helpers.write_beams(modules, dir)

      for kind <- [:Model, :Projection, :Command] do
        module = Module.concat([prefix, kind])

        # Positive control: the oracle is a real docs chunk that holds the
        # docs the compiler attaches.
        assert {:docs_v1, _, _, _, _, _, _} = chunk = Code.fetch_docs(beams[module])
        oracle = Helpers.oracle_function_docs(chunk)

        for {key, doc} <- @written do
          assert Map.fetch!(oracle, key) == doc, "oracle of #{inspect(module)} #{inspect(key)}"
        end

        pd_functions = module.__pd_docs__().functions

        for {key, _doc} <- @written do
          assert Map.fetch!(pd_functions, key).doc == Map.fetch!(oracle, key),
                 "#{inspect(module)} #{inspect(key)}"
        end
      end
    end

    test "an impl without a doc reads what the compiler attaches" do
      prefix = "PropertyDamage.Test.DocsImpl#{Helpers.suffix()}"
      dir = tmp_dir("docs_impl")
      modules = Helpers.compile_with_docs(differential_source(prefix), Path.join(dir, "impl.exs"))
      on_exit(fn -> Helpers.purge(modules) end)
      beams = Helpers.write_beams(modules, dir)

      model = Module.concat([prefix, :Model])
      oracle = beams[model] |> Code.fetch_docs() |> Helpers.oracle_function_docs()

      assert oracle[{:commands, 0}] == false
      assert model.__pd_docs__().functions[{:commands, 0}].doc == false
    end
  end

  describe "modules compiled from scripts" do
    defp script_source(prefix) do
      """
      defmodule #{prefix}.Model do
        @moduledoc "Script model."
        use PropertyDamage.Model

        @impl true
        # line:model.commands
        def commands, do: []

        @doc "Names the projection."
        @impl true
        # line:model.command_sequence_projection
        def command_sequence_projection, do: #{prefix}.Projection

        @doc "Classifies by sign."
        # line:model.classify
        def classify(n) when n > 0, do: :positive
        def classify(_), do: :other

        # line:model.undocumented
        def undocumented, do: :none
      end

      defmodule #{prefix}.Projection do
        @moduledoc false
        use PropertyDamage.Model.Projection

        @impl true
        # line:projection.init
        def init, do: %{}

        @doc "Applies an event."
        @impl true
        # line:projection.apply
        def apply(state, _event), do: state

        @check every: 1
        @doc "Always holds."
        # line:projection.assert_holds
        def assert_holds(_state, _event), do: true
      end

      defmodule #{prefix}.Command do
        use PropertyDamage.Command

        @impl true
        @doc "Generates an empty command."
        # line:command.generator
        def generator(_overrides), do: StreamData.fixed_map([])

        @doc false
        # line:command.internal
        def internal, do: :internal
      end
      """
    end

    test "the macros capture docs that Code.fetch_docs cannot find" do
      prefix = "PropertyDamage.Test.DocsScript#{Helpers.suffix()}"
      source = script_source(prefix)
      file = Path.join(tmp_dir("docs_script"), "script.exs")
      markers = Helpers.marker_lines(source)
      modules = compile!(source, file)

      model = Module.concat([prefix, :Model])
      projection = Module.concat([prefix, :Projection])
      command = Module.concat([prefix, :Command])

      expected = [
        {model, "Script model.",
         %{
           {:commands, 0} => %{doc: false, line: markers["model.commands"]},
           {:command_sequence_projection, 0} => %{
             doc: "Names the projection.",
             line: markers["model.command_sequence_projection"]
           },
           {:classify, 1} => %{doc: "Classifies by sign.", line: markers["model.classify"]},
           {:undocumented, 0} => %{doc: nil, line: markers["model.undocumented"]}
         }},
        {projection, false,
         %{
           {:init, 0} => %{doc: false, line: markers["projection.init"]},
           {:apply, 2} => %{doc: "Applies an event.", line: markers["projection.apply"]},
           {:assert_holds, 2} => %{doc: "Always holds.", line: markers["projection.assert_holds"]}
         }},
        {command, nil,
         %{
           {:generator, 1} => %{
             doc: "Generates an empty command.",
             line: markers["command.generator"]
           },
           {:internal, 0} => %{doc: false, line: markers["command.internal"]}
         }}
      ]

      assert modules |> Map.keys() |> Enum.sort() == Enum.sort([model, projection, command])

      for {module, moduledoc, functions} <- expected do
        docs = module.__pd_docs__()

        assert docs |> Map.keys() |> Enum.sort() == [:file, :functions, :moduledoc]
        assert docs.moduledoc == moduledoc
        assert docs.file == file
        assert Map.take(docs.functions, Map.keys(functions)) == functions

        # Control: the script case is the one where the compiler's own docs
        # are missing, so the captured map is the only source.
        assert Code.fetch_docs(module) == {:error, :module_not_found}

        assert PropertyDamage.Docs.fetch(module) == {:ok, docs}
      end
    end
  end
end
