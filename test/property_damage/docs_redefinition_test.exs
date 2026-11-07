defmodule PropertyDamage.DocsRedefinitionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.DocsHelpers, as: Helpers
  alias PropertyDamage.Test.TmpPath

  # A function defined in several clauses, or defined again after
  # `defoverridable`, must read the doc the compiler attaches. The captured
  # line is the first clause of the definition that wins.

  defp tmp_dir(prefix) do
    dir = TmpPath.unique(prefix)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Compiles the source as written and answers the captured functions of
  # `module_name`, the diagnostics, and the marker lines.
  defp capture(source_for, module_name) do
    prefix = "PropertyDamage.Test.DocsRedefinition#{Helpers.suffix()}"
    source = source_for.(prefix)
    file = Path.join(tmp_dir("docs_redefinition"), "source.exs")
    {modules, diagnostics} = Helpers.compile_with_diagnostics(source, file)
    on_exit(fn -> Helpers.purge(modules) end)

    module = Module.concat([prefix, module_name])
    {module.__pd_docs__().functions, diagnostics, Helpers.marker_lines(source)}
  end

  # Compiles a twin of the source with docs on and answers the docs that
  # `Code.fetch_docs/1` reads from the beam of `module_name`.
  defp oracle(source_for, module_name) do
    prefix = "PropertyDamage.Test.DocsRedefinitionOracle#{Helpers.suffix()}"
    dir = tmp_dir("docs_redefinition_oracle")
    modules = Helpers.compile_with_docs(source_for.(prefix), Path.join(dir, "source.exs"))
    on_exit(fn -> Helpers.purge(modules) end)
    beams = Helpers.write_beams(modules, dir)

    assert {:docs_v1, _, _, _, _, _, _} =
             chunk = Code.fetch_docs(beams[Module.concat([prefix, module_name])])

    Helpers.oracle_function_docs(chunk)
  end

  defp assert_agrees(source_for, module_name, expected) do
    {functions, diagnostics, markers} = capture(source_for, module_name)
    oracle = oracle(source_for, module_name)

    assert diagnostics == []

    for {key, {doc, marker}} <- expected do
      assert Map.fetch!(oracle, key) == doc, "oracle #{inspect(key)}"
      assert Map.fetch!(functions, key) == %{doc: doc, line: markers[marker]}, inspect(key)
    end
  end

  describe "a function defined in several clauses" do
    defp repeated_source(prefix) do
      """
      defmodule #{prefix}.Model do
        @moduledoc false
        use PropertyDamage.Model

        @impl true
        def commands, do: []

        @impl true
        def command_sequence_projection, do: nil

        @doc false
        # line:hidden_then_shown
        def hidden_then_shown(0), do: :zero
        @doc "Shown."
        def hidden_then_shown(_), do: :other

        # line:second_only
        def second_only(0), do: :zero
        @doc "On the second clause."
        def second_only(_), do: :other

        @doc "On the first clause."
        # line:first_only
        def first_only(0), do: :zero
        def first_only(_), do: :other
      end
      """
    end

    defp two_docs_source(prefix) do
      """
      defmodule #{prefix}.Model do
        @moduledoc false
        use PropertyDamage.Model

        @impl true
        def commands, do: []

        @impl true
        def command_sequence_projection, do: nil

        @doc "First."
        # line:both
        def both(0), do: :zero
        @doc "Second."
        def both(_), do: :other
      end
      """
    end

    test "a hidden first clause and a documented second read the second doc" do
      assert_agrees(&repeated_source/1, :Model, %{
        {:hidden_then_shown, 1} => {"Shown.", "hidden_then_shown"}
      })
    end

    test "a doc on the second clause only reads that doc and the first clause line" do
      assert_agrees(&repeated_source/1, :Model, %{
        {:second_only, 1} => {"On the second clause.", "second_only"}
      })
    end

    test "a doc on the first clause only reads that doc" do
      assert_agrees(&repeated_source/1, :Model, %{
        {:first_only, 1} => {"On the first clause.", "first_only"}
      })
    end

    test "a doc on each clause reads the second, as the compiler keeps it" do
      {functions, diagnostics, markers} = capture(&two_docs_source/1, :Model)
      oracle = oracle(&two_docs_source/1, :Model)

      # The compiler warns about the second doc itself; the capture adds nothing.
      assert [%{severity: :warning, message: message}] = diagnostics
      assert message =~ "redefining @doc attribute"

      assert oracle[{:both, 1}] == "Second."
      assert functions[{:both, 1}] == %{doc: "Second.", line: markers["both"]}
    end
  end

  describe "a command that overrides command_spec/1" do
    defp command_source(prefix) do
      """
      defmodule #{prefix}.Documented do
        @moduledoc false
        use PropertyDamage.Command

        @impl true
        def generator(_overrides), do: StreamData.fixed_map([])

        @doc "Custom spec."
        @impl true
        # line:documented
        def command_spec(overrides), do: %{custom: overrides}
      end

      defmodule #{prefix}.Undocumented do
        @moduledoc false
        use PropertyDamage.Command

        @impl true
        def generator(_overrides), do: StreamData.fixed_map([])

        @impl true
        # line:undocumented
        def command_spec(overrides), do: %{custom: overrides}
      end

      defmodule #{prefix}.TwoClauses do
        @moduledoc false
        use PropertyDamage.Command

        @impl true
        def generator(_overrides), do: StreamData.fixed_map([])

        @doc "Two clauses."
        @impl true
        # line:two_clauses
        def command_spec([]), do: %{custom: :empty}
        def command_spec(overrides), do: %{custom: overrides}
      end

      defmodule #{prefix}.Kept do
        @moduledoc false
        # line:use
        use PropertyDamage.Command

        @impl true
        def generator(_overrides), do: StreamData.fixed_map([])
      end
      """
    end

    test "with a doc reads that doc and the line of its own definition" do
      assert_agrees(&command_source/1, :Documented, %{
        {:command_spec, 1} => {"Custom spec.", "documented"}
      })
    end

    test "with an impl and no doc reads false and the line of its own definition" do
      assert_agrees(&command_source/1, :Undocumented, %{
        {:command_spec, 1} => {false, "undocumented"}
      })
    end

    test "in two clauses reads the doc and the line of its first clause" do
      assert_agrees(&command_source/1, :TwoClauses, %{
        {:command_spec, 1} => {"Two clauses.", "two_clauses"}
      })
    end

    test "that does not override keeps the hidden doc and the line of use" do
      assert_agrees(&command_source/1, :Kept, %{
        {:command_spec, 1} => {false, "use"}
      })
    end
  end

  describe "a module that overrides its own overridable function" do
    defp own_source(prefix) do
      """
      defmodule #{prefix}.Model do
        @moduledoc false
        use PropertyDamage.Model

        @impl true
        def commands, do: []

        @impl true
        def command_sequence_projection, do: nil

        @doc false
        def describe(value), do: value
        defoverridable describe: 1

        @doc "Replacement."
        # line:describe
        def describe(value), do: {:replaced, value}

        @doc "Original, kept."
        def label(value), do: value
        defoverridable label: 1

        # line:label
        def label(value), do: {:relabeled, value}
      end
      """
    end

    test "a hidden original and a documented replacement read the replacement doc and line" do
      assert_agrees(&own_source/1, :Model, %{
        {:describe, 1} => {"Replacement.", "describe"}
      })
    end

    test "a replacement without a doc keeps the original doc, as the compiler does" do
      assert_agrees(&own_source/1, :Model, %{
        {:label, 1} => {"Original, kept.", "label"}
      })
    end
  end
end
