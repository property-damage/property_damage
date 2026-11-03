defmodule PropertyDamage.FailureReport.ListingExpansionNoteTest do
  # The note on a root line of the terminal listing that says what a target
  # ran in place of the root: plain words, in the family of the Path item.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ContextSection, as: U

  defp leaf(part), do: "{__P__.Credit, overrides: %{n: n, amount: 1, part: #{part}}}"

  defp define(entries) do
    u = U.define(commands: :refund, entries: entries)
    on_exit(fn -> U.purge(u) end)
    u
  end

  # The listing line of root [0] for one target, with its marker stripped.
  defp root_line(report, target) do
    [_, listings] = String.split(U.terminal(report), "## Minimal Reproduction", parts: 2)
    [listings | _] = String.split(listings, "\n## ", parts: 2)

    [_ | targets] = String.split(listings, ~s(target "))
    section = Enum.find(targets, &String.starts_with?(&1, target <> ~s(")))

    line =
      section
      |> String.split("\n")
      |> Enum.find(&Regex.match?(~r/^[\x{25BA}\s]*\[0\] /u, &1))

    assert line, "no root line for #{target}"
    line |> String.replace(~r/\s+\x{25C4}.*$/u, "") |> String.trim()
  end

  defp note(line), do: line |> String.split("  ") |> List.last()

  test "a root that ran as two leaves says which steps it split into" do
    u = define("[[#{leaf(0)}, #{leaf(1)}]]")
    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert note(root_line(report, "a")) == "split into steps 0.0 and 0.1"
    assert note(root_line(report, "b")) == "split into steps 0.0 and 0.1"
  end

  test "a root that ran as three leaves lists every step" do
    u = define("[[#{leaf(0)}, #{leaf(1)}, #{leaf(2)}]]")
    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert note(root_line(report, "b")) == "split into steps 0.0, 0.1 and 0.2"
  end

  test "a root that ran as one leaf says it split into one step" do
    u = define("[[#{leaf(0)}]]")
    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert note(root_line(report, "a")) == "split into step 0.0"
  end

  test "a root kept as itself under a listed entry says it was kept as one step" do
    u = define("[[%__P__.Refund{n: n, amount: amount}]]")
    report = U.refund_diverged(u, [], [], max_commands: 1)

    assert note(root_line(report, "a")) == "kept as one step"
    assert note(root_line(report, "b")) == "kept as one step"
  end

  test "a root whose entry has no commands says no step ran in its place" do
    u = define("[[]]")
    report = U.refund_diverged(u, [expansion: :identity], [], max_commands: 1)

    assert note(root_line(report, "b")) == "dropped: no step ran in its place"
  end

  test "the listing no longer names the expansion entry" do
    u = define("[[#{leaf(0)}, #{leaf(1)}]]")
    report = U.refund_diverged(u, [], [], max_commands: 1)

    refute U.terminal(report) =~ ~r/ as Refund\[\d+\]/
  end
end
