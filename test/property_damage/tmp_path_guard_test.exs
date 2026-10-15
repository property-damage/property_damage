defmodule PropertyDamage.TmpPathGuardTest do
  use ExUnit.Case, async: true

  # Two test suites running at once on one host share the system tmp dir, and
  # `System.unique_integer/1` restarts at the same value in every VM. A path
  # built from either alone can therefore be the same in both suites, so one
  # suite deletes or overwrites the other's files. Every site that builds a
  # path under the system tmp dir must name the OS pid.

  @helper "test/support/tmp_path.ex"
  @guard "test/property_damage/tmp_path_guard_test.exs"
  @window 3
  @needle "System." <> "tmp_dir"

  defp scanned_files do
    root = Path.expand("../..", __DIR__)

    for pattern <- ["test/**/*.{ex,exs}", "benches/*/test/**/*.{ex,exs}"],
        file <- Path.wildcard(Path.join(root, pattern)),
        rel = Path.relative_to(file, root),
        rel not in [@helper, @guard],
        do: {rel, File.read!(file)}
  end

  defp unsalted_sites do
    for {rel, text} <- scanned_files(),
        lines = String.split(text, "\n"),
        {line, index} <- Enum.with_index(lines, 1),
        String.contains?(line, @needle),
        window = lines |> Enum.slice(index - 1, @window + 1) |> Enum.join("\n"),
        not (window =~ "System.pid()" or window =~ "TmpPath."),
        do: "#{rel}:#{index}"
  end

  test "every tmp path in the suites names the OS pid" do
    assert unsalted_sites() == []
  end

  test "the scan sees the suite files (control)" do
    assert Enum.any?(scanned_files(), fn {rel, _} -> rel == "test/mix/tasks/pd_gen_test.exs" end)
    assert Enum.any?(scanned_files(), fn {rel, _} -> String.starts_with?(rel, "benches/") end)
  end

  describe "TmpPath" do
    alias PropertyDamage.Test.TmpPath

    test "unique/1 names the OS pid and differs per call" do
      a = TmpPath.unique("probe")
      b = TmpPath.unique("probe")

      assert Path.basename(a) =~ "probe_#{System.pid()}_"
      assert a != b
      assert Path.dirname(a) == TmpPath.root()
    end

    test "scoped/1 names the OS pid and is stable per call" do
      assert TmpPath.scoped("probe") == TmpPath.scoped("probe")
      assert Path.basename(TmpPath.scoped("probe")) == "probe_#{System.pid()}"
    end
  end
end
