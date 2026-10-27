defmodule PropertyDamage.Log.LogFilterJsonTest do
  # The `:json` format carries the log lines the terminal shows (DR-054
  # decision 14) under a new top-level `logs` key: the filter applied with its
  # source, the unknown tags, the setup lines once, and, per target, the
  # adapter lines and each step's shown lines and gaps. Hidden lines are in
  # no key. `:compact` and every other `:json` key are unchanged.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.LogFixtures, as: F

  setup do
    F.compile!()
    :ok
  end

  defp json(report, opts \\ []), do: report |> Formatter.format(:json, opts) |> Jason.decode!()

  defp step(target, label), do: Enum.find(target["steps"], &(&1["label"] == label))

  defp messages(lines), do: Enum.map(lines, & &1["message"])

  defp filtered_report(extra \\ [], config \\ %{}) do
    setup = [
      F.line("setup plain"),
      F.line("setup seed", tags: [:seed]),
      F.line("setup http", tags: [:http])
    ]

    F.filter_report!(
      [setup_log: setup, log: [only: [:http], except: [:body]]] ++ extra,
      Map.merge(%{setup_log: true, teardown_log: true}, config)
    )
  end

  test "carries the shown lines of a step with every field" do
    logs = filtered_report() |> json() |> Map.fetch!("logs")
    step = step(logs["target"], "[0]")

    assert messages(step["lines"]) == ["plain line", "GET /a", "accept: json"]

    assert [plain, get, headers] = step["lines"]
    assert {plain["tags"], get["tags"], headers["tags"]} == {[], ["http"], ["http", "headers"]}

    for line <- step["lines"] do
      assert line["kind"] == "line"
      assert is_binary(line["file"]) and is_integer(line["line"])
      assert is_integer(line["offset_ms"]) and line["offset_ms"] >= 0
      assert line["attempt"] == 1
    end
  end

  test "labels each step with its root index" do
    logs = filtered_report() |> json() |> Map.fetch!("logs")

    assert Enum.map(logs["target"]["steps"], &{&1["label"], &1["root"]}) |> hd() == {"[0]", 0}
  end

  test "carries the filter with its source and the unknown tags" do
    logs = filtered_report() |> json() |> Map.fetch!("logs")

    assert logs["filter"] == %{"only" => ["http"], "except" => ["body"], "source" => "log_option"}
    assert logs["unknown_tags"] == []

    report = F.filter_report!(log: [only: [:http, :sed]])
    logs = json(report)["logs"]

    assert logs["filter"] == %{
             "only" => ["http", "sed"],
             "except" => nil,
             "source" => "log_option"
           }

    assert logs["unknown_tags"] == ["sed"]
  end

  test "carries a null filter and no unknown tags for a report with no filter" do
    logs = F.filter_report!() |> json() |> Map.fetch!("logs")

    assert logs["filter"] == nil
    assert logs["unknown_tags"] == []
    assert messages(step(logs["target"], "[0]")["lines"]) |> length() == 5
  end

  test "carries the setup lines once and the adapter lines under the target" do
    logs = filtered_report() |> json() |> Map.fetch!("logs")

    assert messages(logs["setup"]) == ["setup plain", "setup http"]
    assert messages(logs["target"]["adapter_teardown"]) == ["teardown by alice"]
    # `setup by alice` is tagged :setup, which `only: [:http]` hides.
    assert logs["target"]["adapter_setup"] == []
    assert logs["reference"] == nil
  end

  test "holds no hidden line anywhere" do
    logs = filtered_report() |> json() |> Map.fetch!("logs")
    text = Jason.encode!(logs)

    for hidden <- ["BODY-HIDDEN", "SEED-HIDDEN", "setup seed", "setup by alice"],
        do: refute(text =~ hidden, "#{hidden} is in the JSON")
  end

  test "carries a gap with its counts, in its place among the lines" do
    config = %{quiet: true, spin_at: 5, spin_detail: true, fail_at: 1}
    report = F.report!(F.SpinModel, [F.target("alice", config)], log: [only: [:http]])
    lines = json(report)["logs"]["target"] |> step("[0]") |> Map.fetch!("lines")

    assert Enum.map(lines, & &1["kind"]) |> Enum.count(&(&1 == "gap")) == 1
    gap = Enum.find(lines, &(&1["kind"] == "gap"))
    assert {gap["attempts"], gap["lines"]} == {1, 2}
    assert Enum.at(lines, 2) == gap
  end

  test "renders a message as text: a string as written, a value inspected, a raise marked" do
    script = %{0 => [{:log, "as written"}, {:value, %{k: 1}}, :raising_fun]}
    report = F.filter_report!([], %{script: script})

    lines = json(report)["logs"]["target"] |> step("[0]") |> Map.fetch!("lines")

    assert messages(lines) == [
             "as written",
             "%{k: 1}",
             "(log line raised: a log function raised on purpose)"
           ]
  end

  test "carries the reference's lines of a comparison beside the target's" do
    targets = [
      F.target("alice", %{quiet: true, script: F.filter_script()}),
      F.target("bob", %{quiet: true, script: F.filter_script(), skew_at: 1})
    ]

    report = F.report!(F.Model, targets, log: [only: [:headers]])
    assert report.kind == :diverged
    logs = json(report)["logs"]

    assert logs["reference"]["name"] == "alice"
    assert logs["target"]["name"] == "bob"

    for side <- [logs["reference"], logs["target"]],
        do: assert(messages(step(side, "[0]")["lines"]) == ["plain line", "accept: json"])
  end

  test "leaves every other JSON key as it was" do
    report = filtered_report()
    plain = report |> Map.put(:log_filter, nil) |> Map.put(:setup_log, []) |> json()

    with_logs = json(report)
    assert Map.keys(with_logs) -- Map.keys(plain) == []
    assert Map.delete(with_logs, "logs") == Map.delete(plain, "logs")
    assert is_map(with_logs["logs"])
  end

  test ":json resolves a filter given in the format options" do
    report = F.filter_report!()
    logs = json(report, log: [only: [:seed]])["logs"]

    assert logs["filter"]["source"] == "log_option"
    assert messages(step(logs["target"], "[0]")["lines"]) == ["plain line", "SEED-HIDDEN"]
  end

  test ":compact is the same with a filter and without" do
    report = filtered_report()
    plain = Map.put(report, :log_filter, nil)

    assert Formatter.format(report, :compact) == Formatter.format(plain, :compact)

    assert Formatter.format(report, :compact, log: [only: [:seed]]) ==
             Formatter.format(plain, :compact)
  end
end
