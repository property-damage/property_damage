# Livebook notebook evaluation (Decision 2), folded into the same gate.
#
# Mechanizes the W7 manual technique: extract the notebook's elixir cells in
# order, drop the `Mix.install` cell (the worker already has PropertyDamage and
# its deps on the code path via the consumer template's ebins), stub the Kino API
# surface the notebook actually uses with no-op stand-ins, and evaluate the cells
# sequentially in ONE accumulating context. Any raised error fails the gate with
# the offending cell's index and heading.
defmodule DocsVerify.Notebook do
  alias DocsVerify.{FenceParser, ElixirSession}

  # No-op stand-ins for the Kino API the notebook calls. Each renderer just
  # returns its argument so cell evaluation never depends on a Livebook runtime.
  @kino_stub """
  defmodule Kino do
    def start_child!(_), do: :ok
  end

  defmodule Kino.Markdown do
    def new(content), do: content
  end

  defmodule Kino.DataTable do
    def new(data), do: data
    def new(data, _opts), do: data
  end

  defmodule Kino.Mermaid do
    def new(content), do: content
  end
  """

  @default_timeout 300_000

  def run(notebook_path, template_dir, ebin_paths, opts) do
    hex_home = Keyword.fetch!(opts, :hex_home)
    run_root = Keyword.fetch!(opts, :run_root)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    cells =
      notebook_path
      |> FenceParser.parse_file()
      |> Enum.filter(&(&1.lang == "elixir"))
      |> Enum.reject(&mix_install?/1)

    doc_dir = setup_dir(run_root, notebook_path, template_dir)
    env = [{"HEX_HOME", hex_home}]
    session = ElixirSession.start(ebin_paths, doc_dir, env)

    # Install the Kino stubs as the first evaluation in the shared context.
    result =
      case ElixirSession.eval(session, @kino_stub, timeout) do
        {:ok, session} -> eval_cells(cells, 1, session, timeout)
        other -> {stub_failure(other), session}
      end

    {status, session} = result
    ElixirSession.stop(session)

    %DocsVerify.DocRunner.Result{
      path: notebook_path,
      status: elem(status, 0),
      tagged_count: length(cells),
      failure: failure_of(status)
    }
  end

  defp eval_cells([], _idx, session, _timeout), do: {{:pass}, session}

  defp eval_cells([cell | rest], idx, session, timeout) do
    case ElixirSession.eval(session, cell.content, timeout) do
      {:ok, session} ->
        eval_cells(rest, idx + 1, session, timeout)

      {:error, message, session} ->
        {{:fail, cell_failure(cell, idx, message)}, session}

      {:timeout, session} ->
        {{:fail, cell_failure(cell, idx, "cell timed out after #{timeout}ms")}, session}
    end
  end

  defp cell_failure(cell, idx, message) do
    heading = cell.heading || "(no heading)"
    %{line: cell.start_line, lang: "elixir", message: "cell #{idx} under #{heading}\n#{message}"}
  end

  defp stub_failure({:error, message, _session}),
    do: {:error, %{line: 0, lang: "elixir", message: "Kino stub failed:\n#{message}"}}

  defp stub_failure({:timeout, _session}),
    do: {:error, %{line: 0, lang: "elixir", message: "Kino stub timed out"}}

  defp failure_of({:pass}), do: nil
  defp failure_of({_status, failure}), do: failure

  defp mix_install?(cell), do: String.contains?(cell.content, "Mix.install")

  defp setup_dir(run_root, notebook_path, template_dir) do
    slug = notebook_path |> String.replace(~r/[\/.]+/, "_") |> String.trim("_")
    dir = Path.join(run_root, slug)
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.ln_s!(Path.expand(Path.join(template_dir, "deps")), Path.join(dir, "deps"))
    File.ln_s!(Path.expand(Path.join(template_dir, "_build")), Path.join(dir, "_build"))
    File.cp!(Path.join(template_dir, "mix.exs"), Path.join(dir, "mix.exs"))
    Path.expand(dir)
  end
end
