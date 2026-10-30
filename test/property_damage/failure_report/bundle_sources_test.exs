defmodule PropertyDamage.FailureReport.BundleSourcesTest do
  # The docs and source files of the modules behind a report: the line range
  # of each function, a source file that is gone, and an adapter, which is
  # captured like a model.
  use ExUnit.Case, async: false

  alias PropertyDamage.Docs
  alias PropertyDamage.FailureReport.HTML
  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.DocsHelpers

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  # A function of three clauses, a private function right after it, and a
  # last function right before the end of the module.
  @body """
    @doc "Picks one of three."
    def pick(:a), do: 1
    def pick(:b), do: 2
    def pick(_other), do: 3
    defp helper(x), do: x + 1
    def last(x) do
      helper(x)
    end
  end
  """

  defp ranged_source(prefix) do
    """
    defmodule #{prefix}.Ranged do
      @moduledoc "Functions with ranges."
      use PropertyDamage.Model

      @impl true
      def commands, do: []

      @impl true
      def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter

    """ <> @body
  end

  defp bare_source(prefix) do
    """
    defmodule #{prefix}.BareAdapter do
      @moduledoc "An adapter declared with the behaviour alone."
      @behaviour PropertyDamage.Adapter

      @impl true
      def setup(config), do: {:ok, config}

      @impl true
      def teardown(_ctx), do: :ok

      @impl true
      def execute(_command, _ctx, _runtime), do: {:ok, []}

      @impl true
      def timeout(_command), do: 30

    """ <> @body
  end

  # The lines the ranges are checked against, read from the source text.
  defp positions(source) do
    %{
      doc: B.line_of(source, ~r/^  @doc "Picks/),
      pick: B.line_of(source, ~r/^  def pick\(:a\)/),
      pick_last: B.line_of(source, ~r/^  def pick\(_other\)/),
      helper: B.line_of(source, ~r/^  defp helper/),
      last: B.line_of(source, ~r/^  def last/),
      lines: length(String.split(String.trim_trailing(source, "\n"), "\n"))
    }
  end

  defp assert_ranges(entry, lines, path) do
    assert entry["file"] == path
    assert entry["lines"] == B.line_count(path)
    assert entry["lines"] == lines.lines

    pick = B.function_entry(entry, :pick, 1)
    assert pick["from"] == lines.pick
    assert pick["from"] != lines.doc, "from must be the def line, not the @doc line"
    assert pick["to"] == lines.pick_last
    assert pick["to"] == lines.helper - 1

    last = B.function_entry(entry, :last, 1)
    assert last["from"] == lines.last
    assert last["to"] == lines.lines - 1
  end

  describe "ranges, for a module with captured docs" do
    test "start a function at its first clause and end it the line before the next function" do
      prefix = "PropertyDamage.Test.BundleRanged#{B.suffix()}"
      source = ranged_source(prefix)
      compiled = B.compile_file(source)
      model = Module.concat([prefix, "Ranged"])
      lines = positions(source)

      report = B.hand_report(model, [{Compare.PayAdapter, "a"}])
      entry = report |> B.build() |> B.module_entry(model)

      assert entry["resolution"] == "captured"
      assert entry["role"] == "model"
      assert entry["moduledoc"] == "Functions with ranges."
      assert_ranges(entry, lines, compiled.file)
      assert entry["source"] == source

      helper = B.function_entry(entry, :helper, 1)
      assert helper["from"] == lines.helper
      assert helper["to"] == lines.last - 1
    end

    test "hold the doc of a function with several clauses once" do
      prefix = "PropertyDamage.Test.BundleRanged#{B.suffix()}"
      B.compile_file(ranged_source(prefix))
      model = Module.concat([prefix, "Ranged"])

      entry =
        model
        |> then(&B.hand_report(&1, [{Compare.PayAdapter, "a"}]))
        |> B.build()
        |> B.module_entry(model)

      assert Enum.count(entry["functions"], &(&1["name"] == "pick")) == 1
      assert B.function_entry(entry, :pick, 1)["doc"] == "Picks one of three."
      assert B.function_entry(entry, :last, 1)["doc"] == nil
    end

    test "start the function of a projection after its attribute and doc lines" do
      system = B.define()
      report = B.run(system)
      entry = report |> B.build() |> B.module_entry(system.ledger)

      def_line = B.line_of(system.source, ~r/^  def assert_not_negative/)
      function = B.function_entry(entry, :assert_not_negative, 2)

      assert function["doc"] == "A payment is never negative."
      assert function["from"] == def_line
      assert function["to"] == def_line + 1
      assert entry["role"] == "projection"
      assert entry["file"] == system.file
    end

    test "end the last function of a command at the line before the end of its module" do
      system = B.define()
      entry = system |> B.run() |> B.build() |> B.module_entry(system.pay)

      counter = B.line_of(system.source, ~r/^defmodule #{Regex.escape(system.prefix)}\.Counter/)
      function = B.function_entry(entry, :generator, 1)

      assert entry["role"] == "command"
      assert function["from"] == B.line_of(system.source, ~r/^  def generator/)
      assert function["to"] == counter - 3
    end
  end

  describe "ranges, for an adapter declared with the behaviour alone" do
    setup do
      prefix = "PropertyDamage.Test.BundleBare#{B.suffix()}"
      source = bare_source(prefix)
      dir = B.tmp_dir()
      file = Path.join(dir, "bare.ex")
      File.write!(file, source)

      compiled = DocsHelpers.compile_with_docs(source, file)
      on_exit(fn -> DocsHelpers.purge(compiled) end)

      beams = B.tmp_dir("pd_bundle_beams")
      DocsHelpers.write_beams(compiled, beams)
      Code.prepend_path(beams)
      on_exit(fn -> Code.delete_path(beams) end)

      adapter = Module.concat([prefix, "BareAdapter"])
      Code.ensure_loaded!(adapter)
      {:ok, adapter: adapter, source: source, path: file}
    end

    test "resolve through the beam, which reports the doc line as the line of the function",
         ctx do
      refute function_exported?(ctx.adapter, :__pd_docs__, 0)
      assert {:ok, docs} = Docs.fetch(ctx.adapter)

      lines = positions(ctx.source)
      assert docs.functions[{:pick, 1}].line == lines.doc
      refute docs.functions[{:pick, 1}].line == lines.pick
    end

    test "give the same ranges as a module with captured docs, from the def line", ctx do
      lines = positions(ctx.source)
      report = B.hand_report(Compare.PlainModel, [{ctx.adapter, "a"}])
      entry = report |> B.build() |> B.module_entry(ctx.adapter)

      assert entry["resolution"] == "beam"
      assert entry["role"] == "adapter"
      assert_ranges(entry, lines, ctx.path)
      assert entry["source"] == ctx.source
    end

    test "list the functions of the beam only, so a private function has no entry", ctx do
      report = B.hand_report(Compare.PlainModel, [{ctx.adapter, "a"}])
      entry = report |> B.build() |> B.module_entry(ctx.adapter)

      refute Enum.any?(entry["functions"], &(&1["name"] == "helper"))
      assert B.function_entry(entry, :pick, 1)["doc"] == "Picks one of three."
    end
  end

  describe "a source file that is gone" do
    setup do
      system = B.define(model_doc: "The ledger model of alice.")
      report = B.run(system)
      File.rm!(system.file)
      {:ok, system: system, report: report}
    end

    test "gives the module's source as missing, with the path", %{system: system, report: report} do
      entry = report |> B.build() |> B.module_entry(system.model)

      assert entry["source"] == %{"missing" => system.file}
      assert entry["file"] == system.file
    end

    test "keeps the moduledoc and the docs of the functions", %{system: system, report: report} do
      bundle = B.build(report)
      entry = B.module_entry(bundle, system.model)

      assert entry["moduledoc"] == "The ledger model of alice."
      assert entry["functions"] != []

      ledger = B.module_entry(bundle, system.ledger)
      check = B.function_entry(ledger, :assert_not_negative, 2)
      assert check["doc"] == "A payment is never negative."
    end

    test "gives every function a null range", %{system: system, report: report} do
      entry = report |> B.build() |> B.module_entry(system.model)

      assert entry["functions"] != []

      for function <- entry["functions"] do
        assert function["from"] == nil, function["name"]
        assert function["to"] == nil, function["name"]
      end
    end

    test "gives the functions no source id, and keeps their names", %{
      system: system,
      report: report
    } do
      bundle = B.build(report)
      commands = bundle |> B.module_entry(system.model) |> B.function_entry(:commands, 0)

      assert commands["id"] == nil
      refute "source:#{inspect(system.model)}.commands/0" in bundle["ids"]
    end

    test "lists the path under missing_sources, once", %{system: system, report: report} do
      bundle = B.build(report)

      assert system.file in bundle["missing_sources"]
      assert bundle["missing_sources"] == Enum.uniq(bundle["missing_sources"])
    end

    test "says so in the bundle of the page", %{system: system, report: report} do
      bundle = report |> HTML.render() |> B.page_bundle()

      assert system.file in bundle["missing_sources"]
      assert B.module_entry(bundle, system.model)["source"] == %{"missing" => system.file}
    end
  end

  describe "a source file that is there" do
    test "lists no path under missing_sources for the modules compiled from it" do
      system = B.define()
      bundle = system |> B.run() |> B.build()

      refute system.file in bundle["missing_sources"]
      assert B.module_entry(bundle, system.model)["source"] == system.source
      assert B.module_entry(bundle, system.model)["lines"] == B.line_count(system.file)
    end
  end

  describe "a module that is not loaded" do
    test "is listed as unavailable, with no file and no source" do
      missing = Module.concat([PropertyDamage.Test.BundleGone, "Adapter#{B.suffix()}"])
      report = B.hand_report(Compare.PlainModel, [{missing, "a"}])
      bundle = B.build(report)
      entry = B.module_entry(bundle, missing)

      assert entry["resolution"] == "unavailable"
      assert entry["role"] == "adapter"
      assert entry["file"] == nil
      assert entry["source"] == nil
      assert entry["moduledoc"] == nil
      assert entry["functions"] == []
      assert bundle["missing_sources"] == []
    end
  end

  describe "an adapter" do
    test "compiled with use PropertyDamage.Adapter resolves through its captured docs, with a file" do
      system = B.define()
      assert function_exported?(system.adapter, :__pd_docs__, 0)

      entry = system |> B.run() |> B.build() |> B.module_entry(system.adapter)

      assert entry["resolution"] == "captured"
      assert entry["role"] == "adapter"
      assert entry["file"] == system.adapter_file
      assert entry["moduledoc"] == "The adapter of the ledger."

      execute = B.function_entry(entry, :execute, 3)
      assert execute["from"] == B.line_of(system.adapter_source, ~r/^  def execute/)
      assert execute["id"] == "source:#{inspect(system.adapter)}.execute/3"
    end

    test "gives the timeout the use macro injects no range and no source id" do
      system = B.define()
      bundle = system |> B.run() |> B.build()
      timeout = bundle |> B.module_entry(system.adapter) |> B.function_entry(:timeout, 1)

      assert timeout["id"] == nil
      assert timeout["from"] == nil
      assert timeout["to"] == nil
      refute "source:#{inspect(system.adapter)}.timeout/1" in bundle["ids"]
      assert "source:#{inspect(system.adapter)}.execute/3" in bundle["ids"]
    end

    test "lists its callbacks and the timeout the use macro injects, as it lists those of a model" do
      system = B.define()

      assert {:ok, docs} = Docs.fetch(system.adapter)
      assert {:setup, 1} in Map.keys(docs.functions)
      assert {:teardown, 1} in Map.keys(docs.functions)
      assert {:execute, 3} in Map.keys(docs.functions)
      assert {:timeout, 1} in Map.keys(docs.functions)
    end

    test "gives the lines its setup/1 logs to the target, under no step" do
      system = B.define()
      target = B.target(system, "alice", %{negative: true, log_setup: true})
      report = B.run(system, [target])

      [listing] = B.build(report)["listing"]

      assert B.count_of(listing["adapter_setup"]) > 0
      assert B.count_of(listing["adapter_teardown"]) == 0

      events = for step <- listing["steps"], entry <- step["entries"], do: entry["event"]
      assert events == [inspect(system.paid)]
    end

    test "counts the setup lines the page shows: none when the filter hides them" do
      system = B.define()
      report = B.run(system, [B.target(system, "alice", %{negative: true, log_setup: true})])

      [shown] = B.build(report)["listing"]
      [hidden] = B.build(report, log: [only: [:http]])["listing"]

      assert B.count_of(shown["adapter_setup"]) > 0
      assert B.count_of(hidden["adapter_setup"]) == 0
    end

    test "keeps a function defined after use in the normal order" do
      prefix = "PropertyDamage.Test.BundleOrder#{B.suffix()}"

      source = """
      defmodule #{prefix}.Adapter do
        @moduledoc "An adapter."
        use PropertyDamage.Adapter

        @impl true
        def setup(config), do: {:ok, config}

        @impl true
        def teardown(_ctx), do: :ok

        @impl true
        def execute(_command, _ctx, _runtime), do: {:ok, []}

        def helper, do: :helper
      end
      """

      B.compile_file(source)
      adapter = Module.concat([prefix, "Adapter"])

      assert function_exported?(adapter, :__pd_docs__, 0)
      assert {:ok, %{functions: functions}} = Docs.fetch(adapter)
      assert Map.has_key?(functions, {:helper, 0})
    end

    test "rejects a function defined before use PropertyDamage.Adapter, naming the function" do
      prefix = "PropertyDamage.Test.BundleOrder#{B.suffix()}"

      source = """
      defmodule #{prefix}.Adapter do
        @moduledoc "An adapter."

        def defined_before_use, do: :early

        use PropertyDamage.Adapter

        @impl true
        def setup(config), do: {:ok, config}

        @impl true
        def teardown(_ctx), do: :ok

        @impl true
        def execute(_command, _ctx, _runtime), do: {:ok, []}
      end
      """

      file = Path.join(B.tmp_dir(), "early.ex")

      error =
        assert_raise CompileError, fn ->
          DocsHelpers.compile_with_diagnostics(source, file)
        end

      message = Exception.message(error)
      assert message =~ "PropertyDamage.Adapter"
      assert message =~ "defined_before_use/0"
    end
  end
end
