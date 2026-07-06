#!/usr/bin/env elixir
# Documentation-verification gate (Wave 9).
#
# Executes the runnable examples in PropertyDamage's user-facing documentation
# against an honest "stranger" consumer environment, so the manual shakedown
# (campaign W1-W8) never has to be repeated by hand.
#
# Corpus: README.md, guides/*.md, benches/*/README.md, shipped agent skills
# (.claude/skills/pd-*/**/*.md, SKILL.md plus references), and the Livebook notebook
# notebooks/property_damage_demo.livemd. A fence is executable only when the line
# immediately above it is exactly `<!-- pd-doc-verify: runnable -->`. See
# Decisions 1-3 in wave_9_doc_verification_gate.md.
#
# Usage (from the repo root):
#     elixir scripts/docs_verify.exs                 # full corpus + notebook
#     elixir scripts/docs_verify.exs guides/quickstart.md [more paths...]
#
# Exit status is 0 only if every runnable fence passed.
#
# Every mix/shell subprocess this gate spawns runs with HEX_HOME pointed at the
# gate's own tmp/ scratch dir, so a run never rewrites the workstation's shared
# ~/.hex/hex.config (which hex corrupts on token refresh). This is also more
# faithful to the stranger environment.

Code.require_file("docs_verify/reporter.exs", __DIR__)
Code.require_file("docs_verify/fence_parser.exs", __DIR__)
Code.require_file("docs_verify/consumer_template.exs", __DIR__)
Code.require_file("docs_verify/shell_session.exs", __DIR__)
Code.require_file("docs_verify/elixir_session.exs", __DIR__)
Code.require_file("docs_verify/doc_runner.exs", __DIR__)
Code.require_file("docs_verify/notebook.exs", __DIR__)

defmodule DocsVerify.CLI do
  alias DocsVerify.{ConsumerTemplate, DocRunner, Notebook, Reporter}

  def main(argv) do
    root = Path.expand(Path.join(__DIR__, ".."))
    tmp_root = Path.join(root, "tmp/docs_verify")
    hex_home = Path.join(tmp_root, "hexhome")
    run_root = Path.join(tmp_root, "run-#{System.system_time(:second)}-#{System.pid()}")

    File.mkdir_p!(hex_home)
    File.mkdir_p!(run_root)

    docs = corpus(root, argv)

    started = System.monotonic_time(:millisecond)
    {cache, template_dir, ebin_paths} = ConsumerTemplate.ensure(root, tmp_root, hex_home)
    IO.puts("consumer template: #{cache} (#{template_dir})")
    IO.puts("running #{length(docs)} document(s)\n")

    opts = [hex_home: hex_home, run_root: run_root]

    results =
      Enum.map(docs, fn doc ->
        result =
          if livebook?(doc) do
            Notebook.run(doc, template_dir, ebin_paths, opts)
          else
            DocRunner.run(doc, template_dir, ebin_paths, opts)
          end

        Reporter.doc_result(rel(result, root))
        result
      end)

    runtime = System.monotonic_time(:millisecond) - started

    meta = %{
      cache: cache,
      first: cache == :cache_miss,
      runtime_ms: runtime
    }

    ok? = Reporter.summary(Enum.map(results, &rel(&1, root)), meta)

    File.rm_rf(run_root)

    System.halt(if(ok?, do: 0, else: 1))
  end

  # Full corpus (in a stable, readable order) or the explicit subset from argv.
  # Shipped pd-* agent skills join the corpus automatically (W9 Decision 6),
  # including their bundled reference docs - skill templates carry runnable
  # exemplars precisely so this gate catches their rot.
  defp corpus(root, []) do
    readme = [Path.join(root, "README.md")]
    guides = Path.wildcard(Path.join(root, "guides/*.md")) |> Enum.sort()
    benches = Path.wildcard(Path.join(root, "benches/*/README.md")) |> Enum.sort()
    skills = Path.wildcard(Path.join(root, ".claude/skills/pd-*/**/*.md")) |> Enum.sort()
    notebook = Path.wildcard(Path.join(root, "notebooks/*.livemd")) |> Enum.sort()
    readme ++ guides ++ benches ++ skills ++ notebook
  end

  defp corpus(root, argv) do
    Enum.map(argv, fn arg ->
      if Path.type(arg) == :absolute, do: arg, else: Path.expand(arg, root)
    end)
  end

  defp livebook?(path), do: String.ends_with?(path, ".livemd")

  # Present paths relative to the repo root for readable output.
  defp rel(%{path: path} = result, root), do: %{result | path: Path.relative_to(path, root)}
end

DocsVerify.CLI.main(System.argv())
