defmodule PropertyDamage.DocsEarlierUseTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  # A function that another `use` defines above the first `use` of a macro is
  # a compile error even when the module overrides it later: the macros never
  # saw the original definition, so they cannot know the doc the compiler
  # keeps for the override. The error names every such function at once.

  @declarations [
    {"use PropertyDamage.Model",
     """
       @impl PropertyDamage.Model
       def commands, do: []

       @impl PropertyDamage.Model
       def command_sequence_projection, do: nil
     """},
    {"use PropertyDamage.Model.Projection",
     """
       @impl PropertyDamage.Model.Projection
       def init, do: %{}

       @impl PropertyDamage.Model.Projection
       def apply(state, _event), do: state
     """},
    {"use PropertyDamage.Command",
     """
       @impl PropertyDamage.Command
       def generator(_overrides), do: StreamData.fixed_map([])
     """}
  ]

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

  # The functions the error names, after its "move it above".
  defp rejected_at_use(source, use_line) do
    file = Path.join(tmp_dir("docs_earlier_use"), "source.exs")

    error =
      assert_raise CompileError, fn ->
        Helpers.compile_with_diagnostics(source, file)
      end

    assert error.file == file, use_line
    assert error.line == Helpers.marker_lines(source)["use"], use_line

    message = Exception.message(error)
    assert message =~ use_line
    assert [_, names] = Regex.run(~r/move it above (.+), which may come from/, message)
    String.split(names, ", ")
  end

  describe "use GenServer above the first use of a macro" do
    test "is a compile error naming the six defaults even when the module overrides them all" do
      for {use_line, callbacks} <- @declarations do
        source = """
        defmodule PropertyDamage.Test.DocsGenServerOverridden#{Helpers.suffix()} do
          @moduledoc false
          use GenServer

          # line:use
          #{use_line}

        #{callbacks}

          @impl GenServer
          def init(arg), do: {:ok, arg}

          def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

          @impl GenServer
          def handle_call(_message, _from, state), do: {:reply, :ok, state}

          def handle_cast(_message, state), do: {:noreply, state}

          @impl GenServer
          def handle_info(_message, state), do: {:noreply, state}

          @impl GenServer
          def terminate(_reason, _state), do: :ok

          @impl GenServer
          def code_change(_old, state, _extra), do: {:ok, state}
        end
        """

        assert rejected_at_use(source, use_line) ==
                 ~w(child_spec/1 code_change/3 handle_call/3 handle_cast/2 handle_info/2 terminate/2),
               use_line
      end
    end
  end

  describe "an earlier use that defines a function with a default argument" do
    defp earlier_use(overridable) do
      prefix = "PropertyDamage.Test.DocsEarlierDefault#{Helpers.suffix()}"
      file = Path.join(tmp_dir("docs_earlier_default"), "earlier.exs")

      source = """
      defmodule #{prefix} do
        @moduledoc false

        defmacro __using__(_opts) do
          quote do
            @doc "Defined by an earlier use."
            def k(a, b \\\\ 1), do: {a, b}
            defoverridable #{overridable}
          end
        end
      end
      """

      compile(source, file)
      prefix
    end

    defp overriding_source(earlier) do
      """
      defmodule #{earlier}.MyApp.Model do
        @moduledoc false
        use #{earlier}

        # line:use
        use PropertyDamage.Model

        @impl PropertyDamage.Model
        def commands, do: []

        @impl PropertyDamage.Model
        def command_sequence_projection, do: nil

        @doc "Overrides k."
        def k(a, b), do: {:over, a, b}
      end
      """
    end

    test "is a compile error naming both arities when both are overridable and k/2 is overridden" do
      source = overriding_source(earlier_use("k: 1, k: 2"))

      assert rejected_at_use(source, "use PropertyDamage.Model") == ~w(k/1 k/2)
    end

    test "is a compile error naming both arities when only k/2 is overridable and overridden" do
      source = overriding_source(earlier_use("k: 2"))

      assert rejected_at_use(source, "use PropertyDamage.Model") == ~w(k/1 k/2)
    end
  end

  describe "an override of a function that the macro itself defines" do
    test "compiles and keeps the doc and line of the override" do
      module = "PropertyDamage.Test.DocsOwnOverride#{Helpers.suffix()}"
      file = Path.join(tmp_dir("docs_own_override"), "source.exs")

      source = """
      defmodule #{module} do
        @moduledoc false
        use PropertyDamage.Command

        @impl PropertyDamage.Command
        def generator(_overrides), do: StreamData.fixed_map([])

        @doc "Custom spec."
        @impl PropertyDamage.Command
        # line:command_spec
        def command_spec(overrides), do: %{custom: overrides}
      end
      """

      {modules, diagnostics} = compile(source, file)
      assert diagnostics == []

      [compiled] = Map.keys(modules)

      assert compiled.__pd_docs__().functions[{:command_spec, 1}] ==
               %{doc: "Custom spec.", line: Helpers.marker_lines(source)["command_spec"]}
    end
  end
end
