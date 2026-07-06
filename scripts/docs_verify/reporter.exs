# Terminal reporting for the documentation-verification gate.
defmodule DocsVerify.Reporter do
  def doc_result(%{status: :pass, path: path, tagged_count: n}) do
    IO.puts("PASS   #{path}  (#{n} runnable fence#{plural(n)})")
  end

  def doc_result(%{status: :no_runnable, path: path}) do
    IO.puts("- - -  #{path}  (no runnable fences)")
  end

  def doc_result(%{status: :fail, path: path, failure: f}) do
    IO.puts("FAIL   #{path}:#{f.line}  [#{f.lang}]")
    IO.puts(indent(f.message))
  end

  def doc_result(%{status: :error, path: path, failure: f}) do
    IO.puts("ERROR  #{path}:#{f.line}  [#{f.lang}]  (marker misuse)")
    IO.puts(indent(f.message))
  end

  def summary(results, meta) do
    counts = Enum.frequencies_by(results, & &1.status)
    pass = Map.get(counts, :pass, 0)
    fail = Map.get(counts, :fail, 0)
    err = Map.get(counts, :error, 0)
    none = Map.get(counts, :no_runnable, 0)

    IO.puts("")
    IO.puts(String.duplicate("=", 70))

    IO.puts(
      "docs-verify: #{pass} passed, #{fail} failed, #{err} gate errors, " <>
        "#{none} with no runnable fences (#{length(results)} docs)"
    )

    IO.puts(
      "template cache: #{meta.cache}  |  first run: #{meta.first}  |  " <>
        "runtime: #{meta.runtime_ms} ms"
    )

    ok? = fail == 0 and err == 0
    IO.puts(if ok?, do: "RESULT: PASS", else: "RESULT: FAIL")
    IO.puts(String.duplicate("=", 70))
    ok?
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("       " <> &1))
  end
end
