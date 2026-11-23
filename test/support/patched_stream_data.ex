defmodule PropertyDamage.Test.PatchedStreamData do
  @moduledoc false
  # Loads a patched copy of StreamData into the test VM.
  #
  # The patch in stream_data_patch/ adds two seams to StreamData 1.4.0: a :rand
  # state whose algorithm map carries :split splits itself, and a state whose
  # map carries :uniform_range receives both bounds of a range draw. Every
  # other seed behaves exactly as before, so the patched module is a drop-in
  # replacement for the released one.
  #
  # The released dependency stays untouched. `load/0` patches a copy of
  # deps/stream_data/lib/stream_data.ex into _build/<env>/stream_data_patch/,
  # compiles it, and loads the result from a full copy of the stream_data ebin
  # directory there. Dev and prod builds never call it, so they keep the
  # released StreamData.
  #
  # The ebin copy matters because some tests start a fresh VM with the
  # directory of `:code.which(StreamData)` on its code path and then start the
  # :stream_data application. Loading the patched modules from a directory
  # that also holds stream_data.app and the unpatched beams keeps that working.
  #
  # `active?/0` probes behavior rather than files: it draws one integer through
  # a :rand state carrying :split and :uniform_range handlers and reports
  # whether the range handler ran. The :split handler keeps the state intact
  # across the split that precedes every draw.

  @patch Path.expand("stream_data_patch/stream_data_1.4.0.patch", __DIR__)
  @skip_env "PD_SKIP_STREAM_DATA_PATCH"

  @doc """
  Patches and loads StreamData unless the skip variable is set to "1".

  Returns `:ok`, `:skipped`, or `{:error, reason}`.
  """
  def load do
    if System.get_env(@skip_env) == "1", do: :skipped, else: patch_and_compile()
  end

  @doc "Whether the loaded StreamData hands range draws to a :rand state handler."
  def active? do
    test_pid = self()
    probe = make_ref()
    {algorithm, state} = :rand.seed_s(:exsss, {1, 2, 3})

    uniform_range = fn left, _right, seed ->
      send(test_pid, probe)
      {left, seed}
    end

    handlers = %{split: fn seed -> {seed, seed} end, uniform_range: uniform_range}
    seed = {Map.merge(algorithm, handlers), state}

    StreamData.check_all(StreamData.integer(1..10), [initial_seed: seed, max_runs: 1], fn
      value -> {:ok, value}
    end)

    receive do
      ^probe -> true
    after
      0 -> false
    end
  end

  defp patch_and_compile do
    dir = Path.join(Mix.Project.build_path(), "stream_data_patch")
    File.mkdir_p!(dir)

    with {:ok, patch} <- find_patch_executable(),
         {:ok, source} <- pristine_source(),
         {:ok, copy} <- write_patched_copy(patch, source, dir) do
      copy |> compile() |> install(Path.join(dir, "ebin"))
    end
  end

  defp find_patch_executable do
    case System.find_executable("patch") do
      nil -> {:error, "no patch executable on PATH"}
      path -> {:ok, path}
    end
  end

  defp pristine_source do
    source = Path.join(Mix.Project.deps_paths()[:stream_data], "lib/stream_data.ex")
    if File.regular?(source), do: {:ok, source}, else: {:error, "#{source} not found"}
  end

  # Two suites can run at once in one checkout, so each VM writes every file
  # under a name carrying its OS pid and renames it into place. A rename is
  # atomic, so neither VM reads a file the other is still writing.
  defp write_patched_copy(patch, source, dir) do
    scratch = Path.join(dir, "stream_data.#{System.pid()}.ex")

    args = [
      "--batch",
      "--silent",
      "--fuzz=0",
      "--no-backup-if-mismatch",
      "--reject-file=-",
      "--output=" <> scratch,
      source,
      @patch
    ]

    case System.cmd(patch, args, stderr_to_stdout: true) do
      {_output, 0} ->
        copy = Path.join(dir, "stream_data.ex")
        File.rename!(scratch, copy)
        {:ok, copy}

      {output, status} ->
        File.rm(scratch)
        {:error, "patch exited #{status}: #{String.trim(output)}"}
    end
  end

  # Recompiling StreamData over the loaded modules raises two known warnings.
  # Each module gets a "redefining module" warning, which the
  # ignore_module_conflict compiler option silences for this one compile. The
  # Enumerable and Inspect implementations get an "already consolidated"
  # warning; it is harmless here because the consolidated protocols still
  # dispatch to the same implementation modules, whose code only calls into
  # StreamData. The compile collects its diagnostics and prints every one
  # except those consolidation warnings.
  defp compile(copy) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      {modules, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(copy) end)
      diagnostics |> Enum.reject(&consolidation_warning?/1) |> Enum.each(&Code.print_diagnostic/1)
      modules
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  # Copies the released stream_data ebin directory, overwrites the beams of the
  # patched modules, and reloads those modules from the copy. The purge drops
  # the released code that the in-memory compile left behind as old code; no
  # process runs it this early in the suite.
  defp install(modules, ebin) do
    File.mkdir_p!(ebin)
    released = Path.join(:code.lib_dir(:stream_data), "ebin")

    for file <- File.ls!(released) do
      write_atomically(Path.join(ebin, file), File.read!(Path.join(released, file)))
    end

    for {module, binary} <- modules do
      beam = Path.join(ebin, "#{module}.beam")
      write_atomically(beam, binary)
      :code.purge(module)
      {:module, ^module} = :code.load_abs(String.to_charlist(Path.rootname(beam)))
    end

    true = Code.prepend_path(ebin)
    :ok
  end

  defp write_atomically(path, content) do
    scratch = "#{path}.#{System.pid()}"
    File.write!(scratch, content)
    File.rename!(scratch, path)
  end

  defp consolidation_warning?(%{severity: :warning, message: message}) do
    message =~
      ~r/^the (Enumerable|Inspect) protocol has already been consolidated, an implementation for StreamData has no effect/
  end

  defp consolidation_warning?(_diagnostic), do: false
end
