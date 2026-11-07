defmodule PropertyDamage.DocsRobustnessTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Docs
  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  # Another `use` placed above the first `use` of a macro can define functions
  # the macros never see, so those functions are a compile error like a def
  # written there by hand. A macro or a `__`-prefixed function is never
  # captured, so it may come first. `fetch/1` answers `:unavailable` rather
  # than raise or answer something that is not a docs map when the captured
  # map is gone from the beam.

  @gen_server_defaults ~w(child_spec/1 code_change/3 handle_call/3 handle_cast/2 handle_info/2 terminate/2)

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

  defp assert_rejected_at_use(source, use_line) do
    file = Path.join(tmp_dir("docs_robustness_rejected"), "source.exs")

    error =
      assert_raise CompileError, fn ->
        Helpers.compile_with_diagnostics(source, file)
      end

    assert error.file == file
    assert error.line == Helpers.marker_lines(source)["use"]

    message = Exception.message(error)
    assert message =~ use_line
    message
  end

  describe "a use that defines functions placed above the first use of a macro" do
    test "use GenServer is a compile error at the use line naming each default" do
      for {use_line, callbacks} <- @declarations do
        source = """
        defmodule PropertyDamage.Test.DocsGenServerFirst#{Helpers.suffix()} do
          @moduledoc false
          use GenServer

          # line:use
          #{use_line}

          @impl GenServer
          def init(arg), do: {:ok, arg}

        #{callbacks}
        end
        """

        message = assert_rejected_at_use(source, use_line)

        for function <- @gen_server_defaults do
          assert message =~ function, "#{use_line}: #{function}"
        end

        assert not (message =~ "init/1"), use_line
      end
    end

    test "use Agent is a compile error at the use line naming child_spec/1" do
      {use_line, callbacks} =
        List.keyfind(@declarations, "use PropertyDamage.Model.Projection", 0)

      source = """
      defmodule PropertyDamage.Test.DocsAgentFirst#{Helpers.suffix()} do
        @moduledoc false
        use Agent

        # line:use
        #{use_line}

      #{callbacks}
      end
      """

      assert assert_rejected_at_use(source, use_line) =~ "child_spec/1"
    end

    test "use GenServer placed below compiles and its defaults are captured" do
      module = "PropertyDamage.Test.DocsGenServerAfter#{Helpers.suffix()}"
      file = Path.join(tmp_dir("docs_robustness_after"), "source.exs")

      source = """
      defmodule #{module} do
        @moduledoc "A model that is also a server."
        use PropertyDamage.Model

        # line:use_gen_server
        use GenServer

        @impl PropertyDamage.Model
        def commands, do: []

        @impl PropertyDamage.Model
        def command_sequence_projection, do: nil

        @impl GenServer
        def init(arg), do: {:ok, arg}
      end
      """

      {modules, diagnostics} = compile(source, file)
      assert diagnostics == []

      functions =
        modules |> Map.keys() |> hd() |> Docs.fetch() |> elem(1) |> Map.fetch!(:functions)

      line = Helpers.marker_lines(source)["use_gen_server"]

      assert %{doc: doc, line: ^line} = functions[{:child_spec, 1}]
      assert is_binary(doc)

      for {name, arity} <- [
            code_change: 3,
            handle_call: 3,
            handle_cast: 2,
            handle_info: 2,
            terminate: 2
          ] do
        assert functions[{name, arity}] == %{doc: false, line: line}, "#{name}/#{arity}"
      end
    end
  end

  describe "a definition that is never captured placed above the first use" do
    test "a macro and a function whose name starts with __ compile" do
      for {use_line, callbacks} <- @declarations do
        file = Path.join(tmp_dir("docs_robustness_uncaptured"), "source.exs")

        source = """
        defmodule PropertyDamage.Test.DocsUncapturedFirst#{Helpers.suffix()} do
          @moduledoc false

          defmacro twice(value), do: quote(do: unquote(value) * 2)

          def __helper__, do: :helper

          #{use_line}

        #{callbacks}
        end
        """

        {modules, diagnostics} = compile(source, file)
        assert diagnostics == [], use_line

        assert {:ok, %{functions: functions}} = modules |> Map.keys() |> hd() |> Docs.fetch()
        assert not Map.has_key?(functions, {:twice, 1}), use_line
        assert not Map.has_key?(functions, {:__helper__, 0}), use_line
      end
    end
  end

  describe "fetch when the captured map is gone from the beam" do
    test "a beam stripped of its attributes is unavailable" do
      module = Module.concat(["PropertyDamage.Test.DocsStripped#{Helpers.suffix()}"])
      file = Path.join(tmp_dir("docs_robustness_stripped"), "source.exs")

      source = """
      defmodule #{inspect(module)} do
        @moduledoc "Stripped later."
        use PropertyDamage.Model

        @impl true
        def commands, do: []

        @impl true
        def command_sequence_projection, do: nil
      end
      """

      {%{^module => binary}, []} = compile(source, file)
      {:ok, {^module, stripped}} = :beam_lib.strip(binary)

      :code.purge(module)
      :code.delete(module)
      {:module, ^module} = :code.load_binary(module, ~c"stripped.beam", stripped)

      assert module.__info__(:attributes) == []
      assert Docs.fetch(module) == :unavailable
    end

    test "a before_compile after use that deletes or replaces the map leaves nothing to answer" do
      prefix = "PropertyDamage.Test.DocsCollision#{Helpers.suffix()}"
      file = Path.join(tmp_dir("docs_robustness_collision"), "source.exs")

      model_source = fn callback ->
        """
        defmodule #{callback}.Model do
          @moduledoc "Its map is changed after use."
          use PropertyDamage.Model
          @before_compile #{callback}

          @impl true
          def commands, do: []

          @impl true
          def command_sequence_projection, do: nil
        end
        """
      end

      source = """
      defmodule #{prefix}.Deleter do
        @moduledoc false

        defmacro __before_compile__(env) do
          Module.delete_attribute(env.module, :__pd_docs__)
          nil
        end
      end

      defmodule #{prefix}.Replacer do
        @moduledoc false

        defmacro __before_compile__(env) do
          Module.put_attribute(env.module, :__pd_docs__, :mine)
          nil
        end
      end

      #{model_source.("#{prefix}.Deleter")}
      #{model_source.("#{prefix}.Replacer")}
      """

      {modules, diagnostics} = compile(source, file)
      assert diagnostics == []

      for callback <- [Deleter, Replacer] do
        module = Module.concat([prefix, callback, Model])
        assert Map.has_key?(modules, module)
        assert Docs.fetch(module) == :unavailable, inspect(callback)
      end
    end
  end
end
