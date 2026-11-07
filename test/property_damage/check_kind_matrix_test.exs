defmodule PropertyDamage.CheckKindMatrixTest do
  @moduledoc """
  Every reader of a projection's check metadata runs over one projection that
  declares every check form the projection macros emit.

  The set of forms is not written here. `derived_shapes/0` reads it from the
  source of `PropertyDamage.Model.Projection`: a form added to the macros
  without a fixture entry turns `projection coverage` red, and a reader that
  cannot handle the new form turns its own test red.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PropertyDamage.{
    FailureReport,
    Forensics,
    Generator,
    Model,
    PlaceholderRegistry,
    Target,
    Validation,
    Variant
  }

  alias PropertyDamage.FailureReport.Layout
  alias PropertyDamage.LoadTest.{Metrics, Worker}
  alias PropertyDamage.Model.Projection
  alias PropertyDamage.Test.CheckKindMatrix, as: Matrix
  alias PropertyDamage.Test.CheckKindMatrix.Events.{WidgetCreated, WidgetUpdated}

  @checks Matrix.Checks

  # The files under lib that mention `__checks__`:
  #
  #     grep -rln '__checks__' lib
  #
  # Each one has a test below. A file added to or dropped from the output
  # turns `the reader list` red until this list and its tests follow.
  @readers ~w(
    model/projection.ex
    model/projection/checks.ex
  )

  # ==========================================================================
  # Form derivation
  # ==========================================================================

  # The shapes the projection macros can emit, read from the macro source:
  #
  #   * `{type, target}` for each non-raising clause of `normalize_every/1`
  #     (`target` is nil when the clause sets none)
  #   * `{:at, phase}` for each phase `normalize_at/1` accepts
  #   * `{:check_type, type}` for each `type:` of a check definition in
  #     `__on_definition__/6`
  #   * `{:compare, roots, end?}` for each schedule `normalize_compare_every/1`
  #     returns, with `roots` the tag of its `roots:` value
  #
  # When the normalization code moves, change `macro_source/0` only.
  defp derived_shapes do
    ast = macro_source() |> File.read!() |> Code.string_to_quoted!()

    every =
      for clause <- clauses(ast, :normalize_every, 1), shape <- every_shapes(clause), do: shape

    at = for clause <- clauses(ast, :normalize_at, 1), shape <- at_shapes(clause), do: shape

    check_types =
      for clause <- clauses(ast, :__on_definition__, 6),
          {:%{}, _, kw} <- literal_maps(clause),
          Keyword.has_key?(kw, :function_name),
          is_atom(kw[:type]) and kw[:type] != nil,
          do: {:check_type, kw[:type]}

    compares =
      for clause <- clauses(ast, :normalize_compare_every, 1),
          shape <- compare_shapes(clause),
          do: shape

    MapSet.new(every ++ at ++ check_types ++ compares)
  end

  defp macro_source do
    :compile
    |> Projection.module_info()
    |> Keyword.fetch!(:source)
    |> to_string()
  end

  # Every `def`/`defp` clause of `name/arity` in `ast`, as `{guard, body}`.
  defp clauses(ast, name, arity) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          {fname, args, guard} = split_head(head)

          if fname == name and length(args) == arity,
            do: {node, [{guard, body} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp split_head({:when, _, [call, guard]}) do
    {name, args, _} = split_head(call)
    {name, args, guard}
  end

  defp split_head({name, _, args}), do: {name, args || [], nil}

  defp literal_maps({_guard, body}) do
    {_body, maps} =
      Macro.prewalk(body, [], fn
        {:%{}, _, kw} = map, acc when is_list(kw) -> {map, [map | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(maps)
  end

  # The result of each clause of the `case` in `normalize_every/1`: a map
  # literal is an emitted shape, anything else (a raise) is not.
  defp every_shapes({_guard, body}) do
    {_body, results} =
      Macro.prewalk(body, [], fn
        {:->, _, [_pattern, rhs]} = node, acc -> {node, [last_expression(rhs) | acc]}
        node, acc -> {node, acc}
      end)

    for {:%{}, _, kw} <- Enum.reverse(results), Keyword.has_key?(kw, :type) do
      {kw[:type], literal_atom(kw[:target])}
    end
  end

  defp at_shapes({guard, body}) do
    phases = guard_list(guard)

    for {:%{}, _, kw} <- [last_expression(body)], kw[:type] == :at, phase <- phases do
      {:at, phase}
    end
  end

  # The list in a guard of the form `phase in [:startup, :teardown]`.
  defp guard_list({:in, _, [_var, list]}) when is_list(list), do: list
  defp guard_list(_other), do: []

  defp compare_shapes(clause) do
    {_guard, body} = clause

    {_body, shapes} =
      Macro.prewalk(body, [], fn
        {:ok, {:%{}, _, kw}} = node, acc when is_list(kw) ->
          {node, Enum.map(ends(kw[:end]), &{:compare, source_roots_tag(kw[:roots]), &1}) ++ acc}

        node, acc ->
          {node, acc}
      end)

    shapes
  end

  # A literal `end:` flag is itself; a computed one can be either.
  defp ends(flag) when is_boolean(flag), do: [flag]
  defp ends(_computed), do: [true, false]

  # The tag of a `roots:` value as the source writes it: an atom, a pair, or
  # the AST of a larger tuple.
  defp source_roots_tag(tag) when is_atom(tag), do: tag
  defp source_roots_tag({tag, _second}) when is_atom(tag), do: tag
  defp source_roots_tag({:{}, _, [tag | _rest]}) when is_atom(tag), do: tag

  # The tag of a `roots:` value of a declared schedule.
  defp roots_tag(tag) when is_atom(tag), do: tag
  defp roots_tag(tuple) when is_tuple(tuple), do: elem(tuple, 0)

  defp last_expression({:__block__, _, exprs}), do: List.last(exprs)
  defp last_expression(expr), do: expr

  defp literal_atom(atom) when is_atom(atom), do: atom
  defp literal_atom(_other), do: nil

  # The shapes the fixture projection declares, in the same keys.
  defp fixture_shapes do
    checks =
      for entry <- @checks.__checks__(), shape <- check_shapes(entry), do: shape

    compares =
      for %{schedule: %{roots: roots, end: end?}} <- @checks.__compares__() do
        {:compare, roots_tag(roots), end?}
      end

    MapSet.new(checks ++ compares)
  end

  defp check_shapes(%{type: :polling}), do: [{:check_type, :polling}]

  defp check_shapes(%{type: :synchronous, trigger: %{type: :at, phase: phase}}),
    do: [{:check_type, :synchronous}, {:at, phase}]

  defp check_shapes(%{type: :synchronous, trigger: %{type: type} = trigger}),
    do: [{:check_type, :synchronous}, {type, Map.get(trigger, :target)}]

  # ==========================================================================
  # Fixture helpers
  # ==========================================================================

  defp target, do: %Target{adapter: Matrix.Adapter, config: %{}, name: "Adapter", index: 0}

  defp sequence do
    Matrix.Model
    |> Generator.generate_sequence(max_commands: 10)
    |> Generator.generate_value(7)
  end

  defp fixture_events do
    [
      %WidgetCreated{n: 1},
      %WidgetUpdated{n: 1},
      %WidgetCreated{n: 2},
      %WidgetUpdated{n: 2},
      %WidgetCreated{n: 3}
    ]
  end

  defp check_names, do: Enum.map(@checks.__checks__(), & &1.name)

  # ==========================================================================
  # Derivation guards
  # ==========================================================================

  describe "form derivation" do
    test "reads the forms the macros emit, not an empty set" do
      derived = derived_shapes()

      assert MapSet.size(derived) > 0
      assert {:every_step, nil} in derived
      assert {:at, :teardown} in derived
      assert {:at, :startup} in derived
      assert {:check_type, :polling} in derived
      assert {:compare, :all, false} in derived
    end

    test "the reader list matches the files that mention __checks__" do
      lib = Path.join(Path.dirname(macro_source()), "..")

      found =
        lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(&1 |> File.read!() |> String.contains?("__checks__")))
        |> Enum.map(&Path.relative_to(Path.expand(&1), Path.expand(lib)))
        |> Enum.sort()

      assert found == Enum.sort(@readers)
    end
  end

  # ==========================================================================
  # One test per reader
  # ==========================================================================

  describe "model/projection.ex" do
    test "projection coverage: the fixture declares every form the macros emit" do
      missing = MapSet.difference(derived_shapes(), fixture_shapes())

      assert MapSet.size(missing) == 0,
             "the fixture projection declares no check for these forms: " <>
               inspect(Enum.sort(missing))
    end
  end

  describe "executor.ex" do
    test "a run passes and every check and boundary observation is reached" do
      assert {:ok, result} =
               PropertyDamage.run(
                 model: Matrix.Model,
                 targets: [Matrix.Adapter],
                 max_runs: 3,
                 max_commands: 12,
                 seed: 1
               )

      fired = for {{@checks, name}, count} <- result.check_fires, count > 0, do: name
      assert Enum.sort(fired) == Enum.sort(check_names())

      compared = for {{@checks, name}, _counts} <- result.compare_counts, do: name
      declared = for %{name: name} <- @checks.__compares__(), do: name
      assert Enum.sort(compared) == Enum.sort(declared)
    end
  end

  describe "forensics.ex" do
    @tag :known_defect
    test "analyzes events through a projection that declares every check form" do
      assert {:ok, _result} = Forensics.analyze(events: fixture_events(), model: Matrix.Model)
    end
  end

  describe "load_test/worker.ex" do
    @tag :known_defect
    test "a worker that records check failures runs sequences of the model" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: Matrix.Model,
          target: target(),
          metrics: metrics,
          check_mode: :record
        )

      for _ <- 1..5 do
        assert {:ok, %{commands_run: commands_run, check_failures: 0}} =
                 Worker.execute_sequence(worker)

        assert commands_run > 0
      end

      Worker.stop(worker)
      Metrics.stop(metrics)
    end
  end

  describe "model.ex" do
    test "the invariant catalog lists every check with its kind" do
      listed =
        for entry <- Model.check_catalog(Matrix.Model),
            entry.projection == @checks,
            check <- entry.checks,
            into: %{},
            do: {check.name, check.kind}

      expected = Map.new(check_names(), &{&1, expected_kind(&1)})

      assert listed == expected
    end
  end

  # The kind of each check by its declared form, written out here so that a
  # catalog that misfiles a form is not compared with itself.
  defp expected_kind(:clean_start), do: :lifecycle
  defp expected_kind(:clean_finish), do: :lifecycle
  defp expected_kind(:widgets_visible), do: :eventual
  defp expected_kind(_name), do: :synchronous

  describe "validation.ex" do
    test "validates the model and prints a summary that counts its checks" do
      assert {:ok, warnings} = Validation.validate!(Matrix.Model, Matrix.Adapter)

      output =
        capture_io(fn -> Validation.print_summary(Matrix.Model, Matrix.Adapter, warnings) end)

      assert output =~ "#{inspect(@checks)} (#{length(@checks.__checks__())} checks)"
    end
  end

  describe "suggestions/analyzer.ex" do
    @tag :known_defect
    test "analyzes the model and lists every check as existing" do
      analysis = PropertyDamage.Suggestions.analyze(Matrix.Model)

      assert analysis.events_analyzed > 0
      assert length(analysis.existing_checks) == length(@checks.__checks__())
    end
  end

  describe "failure_report/context.ex" do
    test "locates the check function for a failure that names each fixture check" do
      for check <- @checks.__checks__() do
        failure = PropertyDamage.Failure.check_failed(check.name, "boom", @checks)
        report = %FailureReport{failure_reason: failure, kind: :check_failed}

        assert %{name: name} =
                 report |> Layout.context_items() |> Enum.find(&(&1.label == "Check")),
               "no Check item for #{inspect(check.name)}"

        assert name == "#{inspect(@checks)}.#{check.function_name}/2"
      end
    end
  end

  describe "variant.ex" do
    test "a variant steps a generated sequence of the model to a passing result" do
      sequence = sequence()
      assert sequence.prefix != []

      {:ok, pid} =
        Variant.start_link(
          target: target(),
          model: Matrix.Model,
          commands: sequence.prefix,
          placeholder_registry: sequence.registry || PlaceholderRegistry.new(),
          seed: 1,
          run_number: 0
        )

      assert :ok = Variant.setup(pid)
      assert :ok = Variant.run_setup(pid)
      assert {:ok, _observations} = Variant.advance_to(pid, length(sequence.prefix) - 1)

      assert %{failed_at_index: nil, failure_reason: nil} = Variant.finish(pid)

      Variant.stop(pid)
    end
  end

  # error.ex and failure.ex mention `__checks__/0` in documentation only. They
  # must stay that way: a call needs a reader test above.
  for file <- ~w(error.ex failure.ex) do
    describe "#{file}" do
      test "contains no call to __checks__" do
        calls = checks_calls(unquote(file))

        assert calls == [],
               "#{unquote(file)} now calls __checks__ (line #{inspect(calls)}); " <>
                 "add a reader test for it in this file"
      end
    end
  end

  # The lines of `file` (relative to lib/property_damage) that call
  # `__checks__` or name it as an atom, ignoring documentation and comments.
  defp checks_calls(file) do
    path = Path.join([Path.dirname(macro_source()), "..", file]) |> Path.expand()

    {_ast, lines} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(columns: false)
      |> Macro.prewalk([], fn
        {{:., meta, [_module, :__checks__]}, _, _} = node, acc -> {node, [meta[:line] | acc]}
        {:__checks__, meta, args} = node, acc when is_list(args) -> {node, [meta[:line] | acc]}
        :__checks__ = atom, acc -> {atom, [:atom | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(lines)
  end
end
