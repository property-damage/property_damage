#!/usr/bin/env elixir
# Failure-report excerpt tool.
#
# The guides show failure reports as `text` fences. A hand-edited or stale
# excerpt misleads readers, so this tool regenerates each one from a real run
# and either compares it with the guide (--check) or rewrites the guide
# (--write). Never edit an excerpt by hand.
#
# Usage (from the repo root):
#     elixir scripts/regen_report_excerpts.exs --check [guide ...]
#     elixir scripts/regen_report_excerpts.exs --write [guide ...]
#
# Without guide arguments it scans README.md and guides/*.md. Exit status of
# --check is 0 when every excerpt matches, 1 when one differs, 2 on a
# usage error or an excerpt with no generator.
#
# Markers (the line directly above a fence):
#     <!-- pd-report-excerpt: <spec> -->   the fence body is the excerpt
#     <!-- pd-example: <path> -->          the fence body is a file of the
#                                          guide's example project (it may sit
#                                          above a `pd-doc-verify` marker)
#
# A <spec> is looked up in @specs below by {guide file name, spec}. Two kinds
# of generator exist:
#   {:example, source_guide, script, env, slice}
#       builds a consumer project from the `pd-example` fences of source_guide
#       (with a path dependency on this checkout), removes its replay
#       directory, runs `mix run <script>` and takes the output.
#   {:fixture, script_source, slice}
#       runs the script with `MIX_ENV=test mix run` in this checkout, where
#       test/support is compiled, and takes the output.
# slice is :all, or {:between, from_regex, to_regex} for the lines strictly
# between the first line matching from_regex and the next matching to_regex.
#
# --check compares after normalizing the values that change between runs:
# event offsets (+S.SSs), the waited time of a comparison (after N ms) and
# pids. Scratch files live under tmp/ (gitignored). Each generated excerpt is
# also written to tmp/report_excerpts/ for inspection.

defmodule ReportExcerpts do
  @root Path.expand(Path.join(__DIR__, ".."))
  @scratch Path.join(@root, "tmp/report_excerpts")
  @hex_home Path.join(@root, "tmp/docs_verify/hexhome")

  @spin_fixture """
  alias PropertyDamage.Test.LogFixtures, as: F
  F.compile!()

  report =
    F.report!(F.SpinModel, [
      F.target("alice", %{quiet: true, spin_at: 300, spin_detail: true, fail_at: 1})
    ])

  IO.puts(PropertyDamage.FailureReport.Formatter.format(report, :terminal, color: false))
  """

  @specs %{
    {"log_lines.md", "mix run bug.exs; seed 20"} =>
      {:example, "guides/log_lines.md", "bug.exs", [], :all},
    {"debugging_failures.md", "the bank example of log_lines.md: mix run bug.exs; seed 20"} =>
      {:example, "guides/log_lines.md", "bug.exs", [], :all},
    {"path_equivalence_testing.md", "mix run bug.exs; seed 42"} =>
      {:example, "guides/path_equivalence_testing.md", "bug.exs", [], :all},
    {"log_lines.md", ~s(PD_LOG="only:url,status" mix run bug.exs; seed 20)} =>
      {:example, "guides/log_lines.md", "bug.exs", [{"PD_LOG", "only:url,status"}], :all},
    {"log_lines.md", "mix run no_scope.exs"} =>
      {:example, "guides/log_lines.md", "no_scope.exs", [], :all},
    {"log_lines.md", "mix run setup.exs; seed 20"} =>
      {:example, "guides/log_lines.md", "setup.exs", [], :all},
    {"log_lines.md", "test/support/log_fixtures.ex SpinModel, 300 attempts, step [0]; seed 4242"} =>
      {:fixture, @spin_fixture, {:between, ~r/^\s*\[0\] /, ~r/^\s*\+\d+\.\d\ds event /}}
  }

  def main(argv) do
    {opts, guides, invalid} =
      OptionParser.parse(argv, strict: [write: :boolean, check: :boolean])

    modes = Enum.count([:write, :check], &opts[&1])

    if invalid != [] or modes != 1, do: usage(), else: run(opts, guides)
  end

  defp usage do
    IO.puts(
      :stderr,
      "usage: elixir scripts/regen_report_excerpts.exs (--check | --write) [guide ...]"
    )

    System.halt(2)
  end

  defp run(opts, guides) do
    File.mkdir_p!(@scratch)
    File.mkdir_p!(@hex_home)

    markers = find_markers(guide_paths(guides))
    IO.puts("#{length(markers)} excerpt marker(s) found")

    results =
      Enum.map(markers, fn m ->
        key = {Path.basename(m.guide), m.spec}

        case Map.fetch(@specs, key) do
          {:ok, generator} ->
            text = generate(generator)

            File.write!(
              Path.join(@scratch, slug(elem(key, 0)) <> "__" <> slug(m.spec) <> ".txt"),
              text <> "\n"
            )

            {m, text}

          :error ->
            IO.puts(:stderr, "no generator for #{inspect(key)} at #{rel(m.guide)}:#{m.line}")
            System.halt(2)
        end
      end)

    if opts[:write], do: write(results), else: check(results)
  end

  defp guide_paths([]) do
    [Path.join(@root, "README.md")] ++ Enum.sort(Path.wildcard(Path.join(@root, "guides/*.md")))
  end

  defp guide_paths(args), do: Enum.map(args, &Path.expand(&1, File.cwd!()))

  # Every excerpt marker with the fence that follows it.
  defp find_markers(paths) do
    Enum.flat_map(paths, fn guide ->
      lines = guide |> File.read!() |> String.split("\n")

      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        case Regex.run(~r/^<!-- pd-report-excerpt: (.*) -->\s*$/, line) do
          [_, spec] ->
            unless lines |> Enum.at(n) |> to_string() |> String.starts_with?("```") do
              fail!("#{rel(guide)}:#{n}: the excerpt marker must sit directly above a fence")
            end

            [%{guide: guide, line: n, spec: String.trim(spec), body: fence_body(lines, n)}]

          _ ->
            []
        end
      end)
    end)
  end

  defp fence_body(lines, marker_line) do
    lines
    |> Enum.drop(marker_line + 1)
    |> Enum.take_while(&(not String.starts_with?(&1, "```")))
    |> Enum.join("\n")
  end

  defp generate({:example, source_guide, script, env, slice}) do
    dir = build_example(source_guide)
    File.rm_rf!(Path.join(dir, "property_damage_replays"))

    run_mix!(dir, ["run", "--no-compile", script], env)
    |> take(slice)
  end

  defp generate({:fixture, source, slice}) do
    script = Path.join(@scratch, "fixture_#{System.unique_integer([:positive])}.exs")
    File.write!(script, source)
    out = run_mix!(@root, ["run", script], [{"MIX_ENV", "test"}])
    File.rm(script)
    take(out, slice)
  end

  defp run_mix!(dir, args, env) do
    env = [{"HEX_HOME", @hex_home} | env]

    case System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: false) do
      {out, 0} ->
        String.trim_trailing(out)

      {out, status} ->
        fail!("mix #{Enum.join(args, " ")} in #{rel(dir)} exited #{status}:\n#{out}")
    end
  end

  defp take(text, :all), do: text

  defp take(text, {:between, from, to}) do
    text
    |> String.split("\n")
    |> Enum.drop_while(&(not Regex.match?(from, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not Regex.match?(to, &1)))
    |> Enum.join("\n")
  end

  # A consumer project holding the source guide's `pd-example` files, built
  # once per run.
  defp build_example(source_guide) do
    key = {:built, source_guide}

    with nil <- Process.get(key) do
      dir = Path.join(@scratch, slug(source_guide))
      File.mkdir_p!(dir)
      File.rm_rf!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "mix.exs"), mix_exs())

      files = example_files(Path.join(@root, source_guide))
      if files == [], do: fail!("#{source_guide} has no pd-example fences")

      Enum.each(files, fn {path, body} ->
        full = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, body <> "\n")
      end)

      for args <- [["deps.get"], ["compile"]] do
        env = [{"HEX_HOME", @hex_home}]

        case System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true) do
          {_, 0} ->
            :ok

          {out, status} ->
            fail!("mix #{Enum.join(args, " ")} in #{rel(dir)} exited #{status}:\n#{out}")
        end
      end

      Process.put(key, dir)
      dir
    end
  end

  defp example_files(guide) do
    lines = guide |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      case Regex.run(~r/^<!-- pd-example: (\S+) -->\s*$/, line) do
        [_, path] ->
          rest = Enum.drop(lines, n)
          rest = if String.starts_with?(hd(rest), "<!-- pd-doc-verify"), do: tl(rest), else: rest

          unless String.starts_with?(hd(rest), "```"),
            do: fail!("#{rel(guide)}:#{n}: pd-example is not above a fence")

          body =
            rest
            |> tl()
            |> Enum.take_while(&(not String.starts_with?(&1, "```")))
            |> Enum.join("\n")

          [{path, body}]

        _ ->
          []
      end
    end)
  end

  defp mix_exs do
    """
    defmodule ReportExcerpts.ExampleProject do
      use Mix.Project

      def project do
        [app: :report_excerpts_example, version: "0.1.0", elixir: "~> 1.17", deps: [{:property_damage, path: #{inspect(@root)}}]]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp write(results) do
    results
    |> Enum.group_by(fn {m, _} -> m.guide end)
    |> Enum.each(fn {guide, items} ->
      lines = guide |> File.read!() |> String.split("\n")

      # Replace from the last marker up, so earlier line numbers stay valid.
      lines =
        items
        |> Enum.sort_by(fn {m, _} -> -m.line end)
        |> Enum.reduce(lines, fn {m, text}, acc ->
          {before, rest} = Enum.split(acc, m.line + 1)
          after_body = Enum.drop_while(rest, &(not String.starts_with?(&1, "```")))
          before ++ String.split(text, "\n") ++ after_body
        end)

      File.write!(guide, Enum.join(lines, "\n"))
      IO.puts("wrote #{length(items)} excerpt(s) into #{rel(guide)}")
    end)
  end

  defp check(results) do
    Enum.each(results, fn {m, text} ->
      verdict = if normalize(m.body) == normalize(text), do: "match", else: "DIFFERS"
      IO.puts("#{verdict}  #{rel(m.guide)}:#{m.line}  #{m.spec}")
    end)

    bad = Enum.reject(results, fn {m, text} -> normalize(m.body) == normalize(text) end)
    IO.puts("check: #{length(results) - length(bad)}/#{length(results)} excerpts match")
    System.halt(if(bad == [], do: 0, else: 1))
  end

  defp normalize(text) do
    text
    |> String.replace(~r/\+\d+\.\d\ds/, "+S.SSs")
    |> String.replace(~r/after \d+ ms/, "after N ms")
    |> String.replace(~r/#PID<\d+\.\d+\.\d+>/, "#PID<N>")
  end

  defp slug(s), do: s |> String.replace(~r/[^A-Za-z0-9]+/, "_") |> String.trim("_")
  defp rel(path), do: Path.relative_to(path, @root)

  defp fail!(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end

ReportExcerpts.main(System.argv())
