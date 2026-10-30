defmodule PropertyDamage.FailureReport.BundleIdsTest do
  # The ids of the bundle: one string for every field, context item, step,
  # entry, section and function the page or the bundle names, so that a
  # reader can cite any of them. The tests read the ids a page declares from
  # the page's own text and compare them with the bundle's `ids`.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.ContextSection
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.ReferenceReport, as: R
  alias PropertyDamage.Test.ReportLayout, as: RL

  @kinds RL.kinds() ++ [:also_differed, :setup_check, :poll_timeout, :three_targets, :hand_built]

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    :ok
  end

  # The ids the text of `report` declares, with the `source:` ids of the
  # modules the bundle lists.
  defp expected(report, bundle, text) do
    parsed = B.parse(text, B.default_name(report))

    sources =
      for module <- bundle["modules"],
          id <- B.source_ids(Module.concat([module["module"]])),
          do: id

    B.expected_ids(parsed) ++ sources
  end

  defp assert_ids(report, bundle \\ nil, text \\ nil) do
    bundle = bundle || B.build(report)
    text = text || B.page_text(report)

    assert Enum.sort(bundle["ids"]) == Enum.sort(expected(report, bundle, text))
    assert bundle["ids"] == Enum.uniq(bundle["ids"]), "an id is declared twice"
    assert Enum.sort(B.declared_ids(bundle)) == Enum.sort(bundle["ids"])
    bundle
  end

  defp report_for(:branching), do: B.branching_report()
  defp report_for(kind), do: RL.report(kind)

  describe "ids" do
    for kind <- @kinds do
      test "equal the ids the page declares and are the union of the ids in the bundle, for the #{kind} report" do
        assert_ids(report_for(unquote(kind)))
      end
    end

    test "equal the ids the page declares for a poll error report" do
      system = ContextSection.define()
      on_exit(fn -> ContextSection.purge(system) end)

      assert_ids(ContextSection.poll_error(system))
    end

    test "are in the same order every time" do
      report = RL.report(:diverged)

      assert B.build(report)["ids"] == B.build(report)["ids"]
    end
  end

  describe "the Failure fields" do
    test "get the label as printed, spaces kept" do
      report = RL.report(:test_code_error)
      ids = B.build(report)["ids"]

      for label <- ["Failure", "Check", "Projection", "At", "Message", "What went wrong", "Hint"] do
        assert "failure:#{label}" in ids
      end
    end

    test "number the second and later field of one label in print order" do
      report = RL.report(:also_differed)
      ids = B.build(report)["ids"]

      assert "failure:Also differed" in ids
      assert "failure:Also differed:2" in ids
      refute "failure:Also differed:3" in ids
      refute "failure:Also differed:1" in ids
      assert Enum.count(ids, &String.starts_with?(&1, "failure:Also differed")) == 2
    end

    test "get one id per printed field, for each label once" do
      report = RL.report(:also_differed)
      ids = B.build(report)["ids"]

      assert ids |> Enum.filter(&String.starts_with?(&1, "failure:")) |> Enum.sort() ==
               Enum.sort([
                 "failure:Failure",
                 "failure:Observation",
                 "failure:At",
                 "failure:Reference",
                 "failure:Variant",
                 "failure:Compared",
                 "failure:Also differed",
                 "failure:Also differed:2"
               ])
    end
  end

  describe "the context items" do
    test "get the label as printed" do
      ids = B.build(RL.report(:check_failed))["ids"]

      for label <- ["Check failed", "Model", "Check", "Projection", "Command"] do
        assert "context:#{label}" in ids
      end
    end

    test "number the second and later item of one label" do
      ids = B.build(RL.report(:also_differed))["ids"]

      assert "context:Also differed" in ids
      assert "context:Also differed:2" in ids
      refute "context:Also differed:3" in ids
    end

    test "number the second Path item of a comparison in which both targets ran an entry" do
      system =
        ContextSection.define(
          commands: :refund,
          entries: ~s|[{credits(n, amount), doc: "Two credits."}]|
        )

      on_exit(fn -> ContextSection.purge(system) end)
      report = ContextSection.refund_diverged(system, [], [], max_commands: 1)

      bundle = assert_ids(report)
      assert "context:Path" in bundle["ids"]
      assert "context:Path:2" in bundle["ids"]
      refute "context:Path:3" in bundle["ids"]
    end
  end

  describe "the steps and entries of a comparison" do
    setup do
      model = R.pay_model(PropertyDamage.Test.BundleIds.LedgerModel, R.Ledger)

      report =
        R.run(model, [R.pay_target("my app"), R.pay_target("MyApp:v2", %{at: %{1 => {:sync, 1}}})])

      {:error, report} = report
      {:ok, report: report}
    end

    test "name a target with a space and a target with a colon as the listing prints it", %{
      report: report
    } do
      bundle = assert_ids(report)

      listed = Enum.filter(bundle["ids"], &String.starts_with?(&1, ["step:", "entry:"]))

      assert Enum.sort(listed) ==
               Enum.sort([
                 "step:my app:[0]",
                 "step:my app:[1]",
                 "step:my app:[2]",
                 "entry:my app:[0]:1",
                 "entry:my app:[0]:2",
                 "entry:my app:[1]:1",
                 "entry:my app:[1]:2",
                 "step:MyApp:v2:[0]",
                 "step:MyApp:v2:[1]",
                 "step:MyApp:v2:[2]",
                 "entry:MyApp:v2:[0]:1",
                 "entry:MyApp:v2:[0]:2",
                 "entry:MyApp:v2:[1]:1",
                 "entry:MyApp:v2:[1]:2"
               ])
    end

    test "name the targets in the listing with the same names", %{report: report} do
      bundle = B.build(report)

      assert Enum.map(bundle["listing"], & &1["name"]) == ["my app", "MyApp:v2"]

      for target <- bundle["listing"], step <- target["steps"] do
        assert step["id"] == "step:#{target["name"]}:#{step["label"]}"

        for entry <- step["entries"] do
          assert entry["id"] == "entry:#{target["name"]}:#{step["label"]}:#{entry["n"]}"
        end
      end
    end

    test "number the entries of a step from 1 in print order", %{report: report} do
      [_reference, variant] = B.build(report)["listing"]
      [first | _] = variant["steps"]

      assert Enum.map(first["entries"], & &1["n"]) == [1, 2]

      assert Enum.map(first["entries"], & &1["event"]) ==
               ["PropertyDamage.Test.Compare.Paid", "PropertyDamage.Test.Compare.Settled"]
    end
  end

  describe "the steps of a branching run" do
    test "keep the labels the page prints, branch labels and a name with a space" do
      report = B.branching_report()

      bundle = assert_ids(report)

      assert bundle["ids"]
             |> Enum.filter(&String.starts_with?(&1, "step:"))
             |> Enum.sort() ==
               Enum.sort([
                 "step:my app:[0]",
                 "step:my app:[branch 0.0]",
                 "step:my app:[branch 0.1]",
                 "step:my app:[branch 1.0]",
                 "step:my app:[4]"
               ])
    end
  end

  describe "the steps of an expanded root" do
    test "name the leaves of each side as the page prints them" do
      bundle = assert_ids(RL.report(:diverged_expanded))

      steps = Enum.filter(bundle["ids"], &String.starts_with?(&1, "step:"))

      assert Enum.sort(steps) ==
               Enum.sort(["step:a:[0]", "step:b:[0]", "step:b:[0.0]", "step:b:[0.1]"])
    end

    test "name a leaf of a context path under each target that ran it" do
      system =
        ContextSection.define(
          commands: :refund,
          entries: ~s|[{credits(n, amount), doc: "Two credits."}]|
        )

      on_exit(fn -> ContextSection.purge(system) end)
      report = ContextSection.refund_diverged(system, [], [], max_commands: 1)

      bundle = assert_ids(report)
      steps = Enum.filter(bundle["ids"], &String.starts_with?(&1, "step:"))

      assert "step:a:[0.0]" in steps
      assert "step:a:[0.1]" in steps
      assert "step:b:[0.1]" in steps
    end
  end

  describe "the steps of a run with setup and teardown commands" do
    test "name the setup and teardown labels as the page prints them" do
      bundle = assert_ids(RL.report(:setup_failed_command))
      steps = Enum.filter(bundle["ids"], &String.starts_with?(&1, "step:"))

      assert Enum.sort(steps) ==
               Enum.sort(
                 for label <-
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
                       ],
                     do: "step:a:#{label}"
               )

      assert "entry:a:[setup 0]:1" in bundle["ids"]
      assert "entry:a:[teardown 0]:1" in bundle["ids"]
    end
  end

  describe "the sections" do
    test "get the heading exactly as the page prints it" do
      report = RL.report(:check_failed)
      bundle = B.build(report)
      headings = B.parse(B.page_text(report), "a").headings

      assert Enum.map(bundle["sections"], & &1["title"]) == headings

      for heading <- headings, do: assert("section:#{heading}" in bundle["ids"])
      assert "section:What this checks" in bundle["ids"]
      assert "section:Failure" in bundle["ids"]
      assert "section:Reproduction" in bundle["ids"]
    end

    test "keep the parenthesis and the inner spacing of a heading" do
      ids = B.branching_report() |> B.build() |> Map.fetch!("ids")

      assert "section:Minimal Reproduction (5 roots)" in ids
      assert "section:Projections at [branch 0.1]   (- before, + after)" in ids
    end

    test "include the Setup section of a report with lines logged before the run" do
      F.compile!()

      report =
        F.filter_report!(
          [setup_log: [F.line("setup plain"), F.line("setup http", tags: [:http])]],
          %{setup_log: true}
        )

      bundle = assert_ids(report)
      assert "section:Setup" in bundle["ids"]
    end

    test "leave out the sections a report does not print" do
      ids = B.build(RL.report(:setup_failed_adapter))["ids"]

      refute "section:Setup" in ids
      refute Enum.any?(ids, &String.starts_with?(&1, "section:Projections"))
    end
  end

  describe "the entries after the log filter" do
    setup do
      F.compile!()
      :ok
    end

    test "count the events the page shows under a step, not its log lines" do
      report = F.filter_report!(log: [only: [:http], except: [:body]])
      bundle = assert_ids(report)

      entries = Enum.filter(bundle["ids"], &String.starts_with?(&1, "entry:"))
      assert Enum.sort(entries) == ["entry:alice:[0]:1", "entry:alice:[1]:1"]

      assert "failure:Log filter" in bundle["ids"]
    end

    test "count the same events when no filter hides a line" do
      report = F.filter_report!()
      bundle = assert_ids(report)

      entries = Enum.filter(bundle["ids"], &String.starts_with?(&1, "entry:"))
      assert Enum.sort(entries) == ["entry:alice:[0]:1", "entry:alice:[1]:1"]
      refute "failure:Log filter" in bundle["ids"]
    end

    test "follow the filter the caller passes, as the page does for the filter of its report" do
      report = F.filter_report!([], %{setup_log: true, teardown_log: true})
      opts = [log: [only: [:http]]]

      text = Formatter.format(report, :terminal, [color: false] ++ opts)
      bundle = B.build(report, opts)

      assert_ids(report, bundle, text)
      assert "failure:Log filter" in bundle["ids"]
      refute "failure:Log filter" in B.build(report)["ids"]
    end
  end

  describe "the functions" do
    test "get one source id per function Docs.fetch lists, private ones included" do
      system = B.define()
      report = B.run(system)
      bundle = assert_ids(report)

      for function <- [
            "commands/0",
            "command_sequence_projection/0",
            "check_projections/0",
            "number/1"
          ] do
        assert "source:#{inspect(system.model)}.#{function}" in bundle["ids"]
      end

      assert "source:#{inspect(system.ledger)}.assert_not_negative/2" in bundle["ids"]
      assert "source:#{inspect(system.adapter)}.execute/3" in bundle["ids"]
    end
  end
end
