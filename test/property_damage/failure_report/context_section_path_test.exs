defmodule PropertyDamage.FailureReport.ContextSectionPathTest do
  # The Path item of the "What this checks" section: one item for each root
  # that a target ran as a listed expansion entry, with the entry's doc, and
  # none for a target that ran the root as itself.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ContextSection, as: U

  @pad String.duplicate(" ", 16)
  @entry_doc "Refund as two credits of equal size."
  @entries ~s|[{credits(n, amount), doc: "#{@entry_doc}"}]|

  setup_all do
    u = U.define(commands: :refund, entries: @entries)
    on_exit(fn -> U.purge(u) end)
    {:ok, u: u}
  end

  defp paths(report),
    do: report |> U.body!(:terminal) |> U.items() |> Enum.filter(&(&1.label == "Path"))

  # The roots a target's listing shows as run through an entry, in order.
  defp expanded_roots(report, target) do
    text = U.terminal(report)
    [_, listings] = String.split(text, "## Minimal Reproduction", parts: 2)
    [listings | _] = String.split(listings, "\n## ", parts: 2)

    listings
    |> String.split(~s(target "))
    |> Enum.find(&String.starts_with?(&1, target <> ~s(")))
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^[\x{25BA}\s]*\[(\d+)\] .* as Refund\[\d+\]/u, line) do
        [_, root] -> [String.to_integer(root)]
        nil -> []
      end
    end)
  end

  defp name(target, root), do: ~s("#{target}" ran Refund as steps [#{root}.0],[#{root}.1])

  test "a target that ran the root as an entry prints its name and the entry's doc", %{u: u} do
    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert [%{head: a, rest: a_doc}, %{head: b, rest: b_doc}] = paths(report)
    assert a == name("a", 0)
    assert b == name("b", 0)
    assert a_doc == [@pad <> @entry_doc]
    assert b_doc == [@pad <> @entry_doc]
  end

  test "the Path items come after the projection, reference first, before the command", %{u: u} do
    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert report |> U.body!(:terminal) |> U.items() |> Enum.map(& &1.label) == [
             "Diverged",
             "Model",
             "Observation",
             "Projection",
             "Path",
             "Path",
             "Command"
           ]
  end

  test "the command item is the refund root, in its first paragraph", %{u: u} do
    item =
      u |> U.refund_diverged([], [], max_commands: 1) |> U.body!(:terminal) |> U.item!("Command")

    assert item.head == inspect(u.refund)
    assert item.rest == U.indent(U.first_paragraph(U.doc(:refund)))
  end

  test "the entry key never appears in the section", %{u: u} do
    report = U.refund_diverged(u, [], [], max_commands: 1)

    for rendering <- [:terminal, :markdown, :html] do
      body = report |> U.body!(rendering) |> Enum.join("\n")
      refute body =~ ~r/Refund\[\d+\]/, "#{rendering}"
      assert body =~ "ran Refund as steps", "#{rendering}"
    end
  end

  test "a target that ran the root as itself by choice prints no Path item", %{u: u} do
    report = U.refund_diverged(u, [expansion: :identity], [], max_commands: 1)

    assert [%{head: head}] = paths(report)
    assert head == name("b", 0)
  end

  test "both targets running the root as itself print no Path item", %{u: u} do
    report =
      U.refund_diverged(u, [expansion: :identity], [expansion: :identity], max_commands: 1)

    assert paths(report) == []
    assert U.body!(report, :terminal) |> Enum.join("\n") =~ "Observation"
  end

  test "a root no listed entry could run is forced and prints no Path item and no gap" do
    u = U.define(commands: :refund, entries: "[[{__P__.Blocked, overrides: %{n: n}}]]")
    on_exit(fn -> U.purge(u) end)

    report = U.refund_diverged(u, [], [], max_commands: 1)
    body = report |> U.body!(:terminal) |> Enum.join("\n")

    assert paths(report) == []
    refute body =~ "add doc:"
    assert body =~ "Observation"
  end

  test "the Path items of several roots follow the roots the listing shows, reference first",
       %{u: u} do
    report = U.refund_diverged(u, [], [], max_commands: 3)

    reference = expanded_roots(report, "a")
    variant = expanded_roots(report, "b")

    assert length(reference) >= 2
    assert variant == reference

    expected = Enum.map(reference, &name("a", &1)) ++ Enum.map(variant, &name("b", &1))
    assert Enum.map(paths(report), & &1.head) == expected
  end

  test "an expansion entry's doc reads from the entry that ran, not from the list's order" do
    entries =
      ~s|[[{__P__.Blocked, overrides: %{n: n}}], {credits(n, amount), doc: "#{@entry_doc}"}]|

    u = U.define(commands: :refund, entries: entries)
    on_exit(fn -> U.purge(u) end)

    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert [%{rest: a_doc}, %{rest: b_doc}] = paths(report)
    assert a_doc == [@pad <> @entry_doc]
    assert b_doc == [@pad <> @entry_doc]
  end

  test "a report with no expansion prints no Path item", %{u: _u} do
    plain = U.define()
    on_exit(fn -> U.purge(plain) end)

    assert plain |> U.diverged() |> paths() == []
  end
end
