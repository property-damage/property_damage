defmodule PropertyDamage.Test.DocsHelpers do
  @moduledoc false
  # Helpers for the doc capture tests: modules compiled from strings, line
  # markers, the compiler's own docs as an oracle, and a text search over a beam.

  @doc "A name part that is unique per OS process and per call."
  def suffix, do: "#{System.pid()}_#{System.unique_integer([:positive])}"

  @doc """
  Maps each own-line `# line:<id>` marker comment in the text to the number of
  the line after it, which holds the first line of the definition it marks.
  """
  def marker_lines(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(~r/^\s*# line:(\S+)\s*$/, line) do
        [_, id] -> [{id, number + 1}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  @doc "Compiles the source as if it were the file, returning `[{module, binary}]`."
  def compile(source, file) do
    {modules, _diagnostics} = compile_with_diagnostics(source, file)
    modules
  end

  @doc """
  Compiles the source with the compiler's docs option on, so the binaries carry
  a docs chunk as they do when a script runs. The suite runs with the option
  off, and the option is global, so one lock serializes the callers.
  """
  def compile_with_docs(source, file) do
    :global.trans({{__MODULE__, :docs_option}, self()}, fn ->
      previous = Code.get_compiler_option(:docs)
      Code.put_compiler_option(:docs, true)

      try do
        compile(source, file)
      after
        Code.put_compiler_option(:docs, previous)
      end
    end)
  end

  @doc "Like `compile/2`, also returning the compiler diagnostics."
  def compile_with_diagnostics(source, file) do
    Code.with_diagnostics(fn -> Code.compile_string(source, file) end)
  end

  @doc "Removes compiled modules from the VM."
  def purge(modules) do
    for {module, _binary} <- modules do
      :code.purge(module)
      :code.delete(module)
    end

    :ok
  end

  @doc "Writes each compiled binary to `dir` and returns `%{module => beam_path}`."
  def write_beams(modules, dir) do
    File.mkdir_p!(dir)

    Map.new(modules, fn {module, binary} ->
      path = Path.join(dir, Atom.to_string(module) <> ".beam")
      File.write!(path, binary)
      {module, path}
    end)
  end

  @doc """
  Translates `Code.fetch_docs/1` output into `%{{name, arity} => doc}` for
  functions: `%{"en" => s}` reads `s`, `:hidden` reads `false`, `:none` reads `nil`.
  """
  def oracle_function_docs({:docs_v1, _anno, _lang, _format, _moduledoc, _meta, entries}) do
    for {{:function, name, arity}, _anno, _sig, doc, _meta} <- entries, into: %{} do
      {{name, arity}, translate_doc(doc)}
    end
  end

  def translate_doc(:hidden), do: false
  def translate_doc(:none), do: nil
  def translate_doc(%{"en" => text}), do: text

  @doc "Every searchable rendering of a beam: raw, per chunk, inflated, and decoded."
  def beam_text(binary) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(binary)

    rendered =
      Enum.flat_map(chunks, fn {id, chunk} ->
        [chunk, inflate(id, chunk), decode(chunk)]
      end)

    Enum.join([binary | rendered], "\n")
  end

  defp inflate(~c"LitT", <<_size::32, compressed::binary>>) do
    :zlib.uncompress(compressed)
  rescue
    _ -> ""
  end

  defp inflate(_id, _chunk), do: ""

  defp decode(chunk) do
    inspect(:erlang.binary_to_term(chunk), limit: :infinity, printable_limit: :infinity)
  rescue
    _ -> ""
  end
end
