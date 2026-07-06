# Runs one markdown document as a per-doc session (Decision 1).
#
# Each document gets one isolated working directory (a cheap symlink overlay on
# the compiled consumer template so docs cannot see each other's artifacts), one
# persistent shell, and one accumulating Elixir context. Tagged fences execute in
# document order in that shared session:
#   * elixir      -> appended to the accumulating Elixir context and evaluated
#   * bash / sh   -> run as shell commands in the session's persistent cwd
#   * anything else, when tagged -> a gate ERROR (marker misuse), never a silent skip
# The first failing fence aborts the document (later fences depend on it) and its
# file:line is reported.
defmodule DocsVerify.DocRunner do
  alias DocsVerify.{FenceParser, ShellSession, ElixirSession}

  defmodule Result do
    # status: :pass | :fail | :error | :no_runnable
    defstruct [:path, :status, :tagged_count, :failure]
  end

  @default_timeout 300_000

  def run(doc_path, template_dir, ebin_paths, opts) do
    hex_home = Keyword.fetch!(opts, :hex_home)
    run_root = Keyword.fetch!(opts, :run_root)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    fences = FenceParser.parse_file(doc_path)
    tagged = Enum.filter(fences, & &1.runnable)

    if tagged == [] do
      %Result{path: doc_path, status: :no_runnable, tagged_count: 0, failure: nil}
    else
      doc_dir = setup_doc_dir(run_root, doc_path, template_dir)
      env = [{"HEX_HOME", hex_home}]

      state = %{
        shell: nil,
        elixir: nil,
        dir: doc_dir,
        ebin: ebin_paths,
        env: env,
        timeout: timeout
      }

      {result, state} = execute(tagged, state, doc_path)

      if state.shell, do: ShellSession.stop(state.shell)
      if state.elixir, do: ElixirSession.stop(state.elixir)

      %Result{
        path: doc_path,
        status: elem(result, 0),
        tagged_count: length(tagged),
        failure: failure_of(result)
      }
    end
  end

  defp failure_of({:pass}), do: nil
  defp failure_of({_status, failure}), do: failure

  defp execute([], state, _doc_path), do: {{:pass}, state}

  defp execute([fence | rest], state, doc_path) do
    case dispatch(fence, state) do
      {:ok, state} ->
        execute(rest, state, doc_path)

      {:fail, message, state} ->
        {{:fail, %{line: fence.start_line, lang: fence.lang, message: message}}, state}

      {:gate_error, message, state} ->
        {{:error, %{line: fence.start_line, lang: fence.lang, message: message}}, state}
    end
  end

  defp dispatch(%{lang: lang} = fence, state) when lang in ["bash", "sh"] do
    state = ensure_shell(state)

    case ShellSession.run(state.shell, fence.content, state.timeout) do
      {:ok, _out, shell} ->
        {:ok, %{state | shell: shell}}

      {:error, code, out, shell} ->
        {:fail, "shell fence exited #{code}\n#{out}", %{state | shell: shell}}

      {:timeout, shell} ->
        {:fail, "shell fence timed out after #{state.timeout}ms", %{state | shell: shell}}
    end
  end

  defp dispatch(%{lang: "elixir"} = fence, state) do
    state = ensure_elixir(state)

    case ElixirSession.eval(state.elixir, fence.content, state.timeout) do
      {:ok, elixir} ->
        {:ok, %{state | elixir: elixir}}

      {:error, message, elixir} ->
        {:fail, message, %{state | elixir: elixir}}

      {:timeout, elixir} ->
        {:fail, "elixir fence timed out after #{state.timeout}ms", %{state | elixir: elixir}}
    end
  end

  defp dispatch(%{lang: lang}, state) do
    {:gate_error,
     "runnable marker sits above a non-executable fence (language #{inspect(lang)}); " <>
       "only bash, sh, and elixir fences may be tagged runnable", state}
  end

  defp ensure_shell(%{shell: nil} = state),
    do: %{state | shell: ShellSession.start(state.dir, state.env)}

  defp ensure_shell(state), do: state

  defp ensure_elixir(%{elixir: nil} = state),
    do: %{state | elixir: ElixirSession.start(state.ebin, state.dir, state.env)}

  defp ensure_elixir(state), do: state

  # Isolated per-doc working dir: a mix project overlay. deps/ and _build/ are
  # symlinked to the compiled template (shared, read-mostly, sequential runs);
  # mix.exs is copied and lib/ is a fresh empty dir so any files a fence writes
  # (save_failure output, generated tests) land here and stay invisible to other
  # docs.
  defp setup_doc_dir(run_root, doc_path, template_dir) do
    slug = doc_path |> String.replace(~r/[\/.]+/, "_") |> String.trim("_")
    dir = Path.join(run_root, slug)
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "lib"))

    File.ln_s!(Path.expand(Path.join(template_dir, "deps")), Path.join(dir, "deps"))
    File.ln_s!(Path.expand(Path.join(template_dir, "_build")), Path.join(dir, "_build"))
    File.cp!(Path.join(template_dir, "mix.exs"), Path.join(dir, "mix.exs"))

    Path.expand(dir)
  end
end
