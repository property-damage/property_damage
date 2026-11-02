defmodule PropertyDamage.FailureReport.BundleShapeTest do
  # The shape of the bundle that every HTML failure page carries: the keys it
  # holds, the listing it describes (read back from the page's own text), the
  # modules behind the report, and the fact that it refers to the page by id
  # and never copies a printed line.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Docs, Failure, FailureReport, Persistence}
  alias PropertyDamage.FailureReport.{Formatter, HTML}
  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.ContextSection
  alias PropertyDamage.Test.ReportLayout, as: RL

  @top ~w(format pd_version failure context listing sections modules ids missing_sources redactions)

  @target_keys ~w(name role adapter steps adapter_setup adapter_teardown untied)
  @step_keys ~w(id label command ran_as failed entries)
  @entry_keys ~w(id n event)
  @module_keys ~w(module role moduledoc file lines source resolution functions redactions)
  @function_keys ~w(id name arity doc from to)
  @section_keys ~w(id title fence)

  @role_order ~w(model projection command event adapter)

  # Every kind of the generic coverage list, plus reports that print a second
  # observation, a setup check, a poll timeout, three targets and an event
  # that belongs to no command.
  @kinds RL.kinds() ++ [:also_differed, :setup_check, :poll_timeout, :three_targets, :hand_built]

  @persistence Path.expand("../../support/fixtures/persistence", __DIR__)

  # Loading a saved report decodes only atoms that exist, so every module is
  # loaded first.
  setup_all do
    Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)
    :ok
  end

  defp keys_present(map, keys, what) do
    missing = keys -- Map.keys(map)
    assert missing == [], "#{what} lacks the keys #{inspect(missing)}: #{inspect(Map.keys(map))}"
  end

  defp assert_top_level(bundle) do
    keys_present(bundle, @top, "the bundle")
    assert bundle["format"] == 1
    assert bundle["pd_version"] == to_string(Application.spec(:property_damage, :vsn))
    assert is_map(bundle["failure"])
    assert is_list(bundle["context"])
    assert is_list(bundle["listing"])
    assert is_list(bundle["sections"])
    assert is_list(bundle["modules"])
    assert is_list(bundle["ids"]) and Enum.all?(bundle["ids"], &is_binary/1)
    assert is_list(bundle["missing_sources"])

    assert %{"count" => count, "rule" => rule} = bundle["redactions"]
    assert is_integer(count) and count >= 0
    assert is_binary(rule) and rule != ""
  end

  defp assert_key_sets(bundle) do
    for section <- bundle["sections"], do: keys_present(section, @section_keys, "a section")

    for target <- bundle["listing"] do
      keys_present(target, @target_keys, "a listing target")

      for step <- target["steps"] do
        keys_present(step, @step_keys, "a step")
        assert is_boolean(step["failed"])
        for entry <- step["entries"], do: keys_present(entry, @entry_keys, "an entry")
      end
    end

    for module <- bundle["modules"] do
      keys_present(module, @module_keys, "a module")

      for function <- module["functions"],
          do: keys_present(function, @function_keys, "a function")
    end
  end

  # The listing of the bundle against the listing the page prints.
  defp assert_listing(bundle, report) do
    parsed = B.parse(B.page_text(report), B.default_name(report))
    listing = bundle["listing"]

    assert Enum.map(listing, &{&1["name"], &1["role"]}) ==
             Enum.map(parsed.targets, &{&1.name, &1.role})

    for {target, page} <- Enum.zip(listing, parsed.targets) do
      assert target["adapter"] == adapter_of(report, page)
      assert Enum.map(target["steps"], & &1["label"]) == Enum.map(page.steps, & &1.label)

      for {step, printed} <- Enum.zip(target["steps"], page.steps) do
        assert step["command"] == printed.command, "command of #{printed.label}"
        assert step["failed"] == printed.failed, "failed flag of #{printed.label}"
        assert Enum.map(step["entries"], & &1["n"]) == Enum.to_list(1..length(printed.events)//1)
        assert Enum.map(step["entries"], & &1["event"]) == printed.events
      end
    end
  end

  defp adapter_of(report, %{name: name}) do
    {adapter, _entry} =
      Enum.find(report.targets, fn {_adapter, entry} -> Keyword.get(entry, :name) == name end)

    inspect(adapter)
  end

  describe "the top level" do
    for kind <- @kinds do
      test "holds every key, and each map holds its keys, for the #{kind} report" do
        report = RL.report(unquote(kind))
        bundle = B.build(report)

        assert_top_level(bundle)
        assert_key_sets(bundle)
      end
    end

    test "holds every key for a poll error report" do
      system = ContextSection.define()
      on_exit(fn -> ContextSection.purge(system) end)
      bundle = system |> ContextSection.poll_error() |> B.build()

      assert_top_level(bundle)
      assert_key_sets(bundle)
    end

    test "holds every key for a branching run" do
      bundle = B.build(B.branching_report())

      assert_top_level(bundle)
      assert_key_sets(bundle)
    end

    test "builds the same bundle twice" do
      report = RL.report(:diverged)

      assert B.build(report) == B.build(report)
    end

    test "carries the format and the version of the application" do
      bundle = B.build(RL.report(:check_failed))

      assert bundle["format"] === 1
      assert bundle["pd_version"] == to_string(Application.spec(:property_damage, :vsn))
      assert bundle["pd_version"] != ""
    end
  end

  describe "the failure" do
    test "names the kind and carries the meaning the first context item prints" do
      report = RL.report(:check_failed)
      bundle = B.build(report)

      kind = report |> FailureReport.failure_type() |> to_string()
      assert bundle["failure"]["kind"] in [kind, String.replace(kind, "_", " ")]

      [first | _] =
        report |> Formatter.format(:json, []) |> Jason.decode!() |> Map.fetch!("what_this_checks")

      assert squash(bundle["failure"]["meaning"]) == squash(first["text"])
    end

    test "holds one field per printed label, each with its id, in print order" do
      report = RL.report(:also_differed)
      bundle = B.build(report)
      parsed = B.parse(B.page_text(report), B.default_name(report))

      assert [fields] = for(value <- Map.values(bundle["failure"]), is_list(value), do: value)

      assert Enum.map(fields, & &1["id"]) ==
               Enum.map(B.with_ordinals(parsed.failure), &"failure:#{&1}")
    end
  end

  describe "the context" do
    for kind <- [:check_failed, :diverged_expanded, :also_differed, :setup_failed_command] do
      test "holds the items of the section, each with its id, for the #{kind} report" do
        report = RL.report(unquote(kind))
        bundle = B.build(report)

        printed =
          report
          |> Formatter.format(:json, [])
          |> Jason.decode!()
          |> Map.fetch!("what_this_checks")

        assert Enum.map(bundle["context"], &Map.delete(&1, "id")) == printed
        assert Enum.all?(bundle["context"], &is_binary(&1["id"]))
      end
    end
  end

  describe "the listing" do
    for kind <- @kinds -- [:branching] do
      test "describes the listing the page prints for the #{kind} report" do
        report = RL.report(unquote(kind))

        assert_listing(B.build(report), report)
      end
    end

    test "describes the branching listing, with the branch labels as printed" do
      report = B.branching_report()
      bundle = B.build(report)

      assert_listing(bundle, report)

      assert [%{"name" => "my app", "role" => "variant", "steps" => steps}] = bundle["listing"]

      assert Enum.map(steps, & &1["label"]) ==
               ["[0]", "[branch 0.0]", "[branch 0.1]", "[branch 1.0]", "[4]"]

      assert Enum.map(steps, & &1["failed"]) == [false, false, true, false, false]
    end

    test "lists the reference before the variant of a comparison" do
      bundle = B.build(RL.report(:diverged))

      assert Enum.map(bundle["listing"], &{&1["name"], &1["role"]}) ==
               [{"a", "reference"}, {"b", "variant"}]
    end

    test "names the leaf steps of an expanded root and the note of the root that ran them" do
      report = RL.report(:diverged_expanded)
      bundle = B.build(report)
      [reference, variant] = bundle["listing"]

      assert Enum.map(reference["steps"], & &1["label"]) == ["[0]"]
      assert Enum.map(variant["steps"], & &1["label"]) == ["[0]", "[0.0]", "[0.1]"]

      [root | leaves] = variant["steps"]
      assert is_binary(root["ran_as"]) and root["ran_as"] != ""
      assert Enum.all?(leaves, &is_nil(&1["ran_as"]))
      assert Enum.all?(reference["steps"], &is_nil(&1["ran_as"]))

      line =
        report
        |> B.page_text()
        |> String.split("\n")
        |> Enum.find(&(String.contains?(&1, "[0]") and String.contains?(&1, "as Refund")))

      assert line, "the page prints no note on the variant's root"
      assert String.contains?(line, root["ran_as"])
    end

    test "gives no step a note when no root ran an expansion entry" do
      bundle = B.build(RL.report(:check_failed))

      steps = for target <- bundle["listing"], step <- target["steps"], do: step
      assert steps != []
      assert Enum.all?(steps, &is_nil(&1["ran_as"]))
    end

    test "marks one step as failed in a check failure" do
      bundle = B.build(RL.report(:check_failed))

      steps = for target <- bundle["listing"], step <- target["steps"], do: step
      assert [_one] = Enum.filter(steps, & &1["failed"])
    end

    test "counts the event that belongs to no command under untied, and files it under no step" do
      report = RL.report(:hand_built)
      bundle = B.build(report)
      [target] = bundle["listing"]

      assert B.count_of(target["untied"]) == 1

      entries = for step <- target["steps"], entry <- step["entries"], do: entry["event"]
      assert Enum.sort(entries) == Enum.sort(~w(
        PropertyDamage.Test.Compare.Paid
        PropertyDamage.Test.Compare.Paid
        PropertyDamage.Test.Compare.Settled
        PropertyDamage.Test.Compare.Settled
      ))

      refute Enum.any?(entries, &(&1 == "PropertyDamage.Test.Compare.Balance"))
    end

    test "names a step of a setup command and a teardown command with its printed label" do
      report = RL.report(:setup_failed_command)
      [target] = B.build(report)["listing"]

      assert Enum.map(target["steps"], & &1["label"]) ==
               [
                 "[setup 0]",
                 "[setup 1]",
                 "[0]",
                 "[1]",
                 "[2]",
                 "[3]",
                 "[4]",
                 "[5]",
                 "[teardown 0]"
               ]

      assert %{"command" => "PropertyDamage.Test.SetupCommands.Login", "failed" => true} =
               Enum.at(target["steps"], 1)
    end
  end

  describe "the modules" do
    for kind <- @kinds -- [:hand_built] do
      test "start with the model, then group by role, with no module twice, for the #{kind} report" do
        report = RL.report(unquote(kind))
        modules = B.build(report)["modules"]

        names = Enum.map(modules, & &1["module"])
        assert names == Enum.uniq(names)

        roles = Enum.map(modules, & &1["role"])
        assert Enum.all?(roles, &(&1 in @role_order))

        assert roles ==
                 Enum.sort_by(roles, fn role -> Enum.find_index(@role_order, &(&1 == role)) end)

        if report.model do
          assert [%{"module" => model, "role" => "model"} | _] = modules
          assert model == inspect(report.model)
        end
      end
    end

    test "hold the model, its projections, the commands, the events and the adapters of a check failure" do
      report = RL.report(:check_failed)
      modules = B.build(report)["modules"]
      by_role = fn role -> for m <- modules, m["role"] == role, do: m["module"] end

      assert by_role.("model") == [inspect(report.model)]

      projection = fn module -> inspect(module) end

      assert Enum.sort(by_role.("projection")) ==
               Enum.sort([
                 projection.(PropertyDamage.Test.Compare.Counter),
                 projection.(PropertyDamage.Test.Compare.Plain)
               ])

      assert by_role.("command") == ["PropertyDamage.Test.Compare.Pay"]

      assert Enum.sort(by_role.("event")) ==
               ["PropertyDamage.Test.Compare.Paid", "PropertyDamage.Test.Compare.Settled"]

      assert by_role.("adapter") == ["PropertyDamage.Test.Compare.PayAdapter"]
    end

    test "hold the commands and events of both sides of a comparison, and both adapters" do
      report = RL.report(:shrunk_not_reproduced)
      modules = B.build(report)["modules"]
      by_role = fn role -> for m <- modules, m["role"] == role, do: m["module"] end

      assert Enum.sort(by_role.("adapter")) ==
               [
                 "PropertyDamage.Test.Compare.PayAdapter",
                 "PropertyDamage.Test.ReferenceReport.FirstExecutionAdapter"
               ]

      assert by_role.("command") == ["PropertyDamage.Test.Compare.Pay"]
    end

    test "hold the commands of the setup and teardown steps" do
      modules = B.build(RL.report(:setup_failed_command))["modules"]
      commands = for m <- modules, m["role"] == "command", do: m["module"]

      for command <- ~w(CreateUser Login Tick Cleanup) do
        assert "PropertyDamage.Test.SetupCommands.#{command}" in commands
      end
    end

    test "hold, per module, the moduledoc and the functions Docs.fetch reports" do
      report = RL.report(:check_failed)

      for entry <- B.build(report)["modules"] do
        module = Module.concat([entry["module"]])

        case Docs.fetch(module) do
          {:ok, docs} ->
            assert entry["moduledoc"] == docs.moduledoc
            fetched = for {{name, arity}, _} <- docs.functions, do: {to_string(name), arity}
            listed = for f <- entry["functions"], do: {f["name"], f["arity"]}
            assert Enum.sort(listed) == Enum.sort(fetched)

          :unavailable ->
            assert entry["resolution"] == "unavailable"
        end
      end
    end

    test "hold the file and the line count of each module that has a readable file" do
      for entry <- B.build(RL.report(:check_failed))["modules"], is_binary(entry["file"]) do
        assert File.regular?(entry["file"]), "the bundle names a file that is not there"
        assert entry["lines"] == B.line_count(entry["file"])
      end
    end

    test "resolve a module through its captured docs, its beam or neither" do
      for entry <- B.build(RL.report(:check_failed))["modules"] do
        module = Module.concat([entry["module"]])

        expected =
          cond do
            not match?({:ok, _}, Docs.fetch(module)) -> "unavailable"
            function_exported?(module, :__pd_docs__, 0) -> "captured"
            true -> "beam"
          end

        assert entry["resolution"] == expected, entry["module"]
      end
    end
  end

  describe "the reference to the page" do
    for kind <- [:check_failed, :diverged, :diverged_expanded, :also_differed] do
      test "copies no printed step line and no printed event line, for the #{kind} report" do
        report = RL.report(unquote(kind))
        bundle = B.build(report)
        parsed = B.parse(B.page_text(report), B.default_name(report))

        assert parsed.lines != []
        values = B.strings(Map.take(bundle, ["listing", "sections"]))

        # A leaf step prints its label alone on its line; the bundle names
        # the label, which is not a copy of the line's text.
        for line <- parsed.lines, not Regex.match?(~r/^\[[^\]]+\]$/, line) do
          refute line in values, "a bundle value equals the printed line #{inspect(line)}"

          refute Enum.any?(values, &String.contains?(&1, line)),
                 "a bundle value holds the printed line #{inspect(line)}"
        end
      end
    end

    test "holds no section text, only the id, the title and the fence of each section" do
      report = RL.report(:check_failed)
      bundle = B.build(report)
      parsed = B.parse(B.page_text(report), B.default_name(report))

      assert Enum.map(bundle["sections"], & &1["title"]) == parsed.headings

      assert Enum.map(bundle["sections"], & &1["id"]) ==
               Enum.map(parsed.headings, &"section:#{&1}")

      text = B.page_text(report)

      for section <- bundle["sections"],
          value <- B.strings(Map.take(section, ["title"])) do
        assert String.contains?(text, "## " <> value)
      end
    end
  end

  describe "a report loaded from a file saved before the bundle existed" do
    for file <- ~w(
          v15_check_failed_without_projection.pd
          v15_poll_timeout_without_projection.pd
          v15_expansion_without_doc.pd
        ) do
      test "builds a bundle with every key, and the page embeds it (#{file})" do
        report = load(Path.join(@persistence, unquote(file)))
        bundle = B.build(report)

        assert_top_level(bundle)
        assert_key_sets(bundle)
        assert B.page_bundle(HTML.render(report)) == bundle
      end
    end

    test "describes the listing its page prints" do
      report = load(Path.join(@persistence, "v15_check_failed_without_projection.pd"))

      assert_listing(B.build(report), report)
    end
  end

  describe "a failure of another kind" do
    test "poll_error builds a bundle whose failure names the kind" do
      system = ContextSection.define()
      on_exit(fn -> ContextSection.purge(system) end)
      report = ContextSection.poll_error(system)

      assert %Failure{} = report.failure_reason
      assert B.build(report)["failure"]["kind"] in ["poll_error", "poll error"]
    end
  end

  defp load(path) do
    case Persistence.load(path) do
      {:ok, report} -> report
      {:ok, report, _warnings} -> report
    end
  end

  defp squash(text), do: text |> String.split() |> Enum.join(" ")
end
