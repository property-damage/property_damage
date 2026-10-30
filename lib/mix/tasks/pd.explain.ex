defmodule Mix.Tasks.Pd.Explain do
  @moduledoc """
  Prints the prompt for a failure page, and puts a model's explanation back into it.

  A failure page written by PropertyDamage carries a machine-readable copy of
  the failure, its bundle. This task gives you that bundle together with
  instructions for writing an explanation, and it checks an explanation you
  bring back before it adds the explanation to the page. The task never calls
  a language model: you, or an agent working for you, run the prompt and
  produce the explanation.

  It reads one page and loads no project code.

  ## Usage

      mix pd.explain PAGE
      mix pd.explain PAGE --prompt
      mix pd.explain PAGE --apply FILE
      mix pd.explain PAGE --apply -

  ## Modes

  Without an option, the task writes the directory `PAGE.explain` (created if
  missing) with two files, `bundle.json` and `instructions.md`, and prints their
  absolute paths, the prompt version and the bundle hash, one per line. It
  overwrites those two files and removes nothing else in the directory.
  `bundle.json` holds the bundle bytes of the page, so `sha256sum bundle.json`
  prints the bundle hash. If the page already holds an explanation of this
  bundle for this prompt version, the task prints one line saying so and writes
  nothing.

  With `--prompt`, the task prints the instructions, a newline, the bundle and a
  newline to standard output, and nothing else. It writes nothing. Pipe it to
  the model of your choice. Mix compiles the project before any task runs, so on
  a first run its compile messages come before the prompt; run `mix compile`
  first, or set `MIX_QUIET=1`, when the output must hold the prompt alone.

  With `--apply FILE` (or `--apply -` for standard input), the task reads an
  explanation as JSON and checks it against the page. It reports every problem it
  finds, one per line on standard error, and leaves the page untouched. If the
  explanation passes, the task adds a `pd-explanation` script tag right after the
  `pd-bundle` tag, replaces any earlier `pd-explanation` tag, and prints one line
  saying so. The page is replaced in one step, so a failure part way leaves the
  old page.

  The `--with CMD` option is reserved. It is not available in this version and
  the task refuses it.

  ## Exit codes

  The task exits with 0 when it did what was asked, including when the page is
  already explained. It exits with 1 on a usage error, on a page it cannot read
  (no bundle, more than one bundle, a bundle that is not JSON, a bundle format
  this version does not read), and on an explanation that fails a check. Every
  error goes to standard error, and standard output stays empty.

  ## Checks on an explanation

  The explanation must have the shape the instructions describe, and any
  `bundle_hash` it names must be the page's. Every id it cites must exist in
  the bundle, and a hypothesis may not cite a context item whose description is
  missing. See `PropertyDamage.FailureReport.Explanation` for the rules.
  """

  use Mix.Task

  alias PropertyDamage.FailureReport.Explanation

  @shortdoc "Print the prompt for a failure page, or apply an explanation to it"

  @usage "usage: mix pd.explain PAGE [--prompt | --apply FILE|-]"

  @impl true
  def run(args) do
    args |> exec() |> halt_on_error()
  end

  # Testable seam: `run/1` turns an `:error` into a halt with status 1, so the
  # decision logic can run in-process without killing the VM.
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args, strict: [prompt: :boolean, apply: :string, with: :string])

    with :ok <- check_options(invalid),
         :ok <- check_with(opts),
         {:ok, page} <- check_page_count(argv),
         :ok <- check_modes(opts),
         :ok <- check_exists(page) do
      run_mode(page, opts)
    else
      {:usage, problem} -> fail([problem, @usage])
      {:fail, lines} -> fail(lines)
    end
  end

  defp halt_on_error(:ok), do: :ok
  defp halt_on_error(:error), do: System.halt(1)

  # --- usage -----------------------------------------------------------------

  defp check_options([]), do: :ok

  defp check_options([{switch, nil} | _]) when switch in ["--apply", "--with"],
    do: {:usage, "mix pd.explain: #{switch} needs a value"}

  defp check_options([{switch, _value} | _]),
    do: {:usage, "mix pd.explain: unknown option #{switch}"}

  defp check_with(opts) do
    if Keyword.has_key?(opts, :with),
      do: {:fail, ["mix pd.explain: --with is not available in this version"]},
      else: :ok
  end

  defp check_page_count([page]), do: {:ok, page}
  defp check_page_count([]), do: {:usage, "mix pd.explain: no PAGE given"}
  defp check_page_count(_several), do: {:usage, "mix pd.explain: more than one PAGE given"}

  defp check_modes(opts) do
    if opts[:prompt] && Keyword.has_key?(opts, :apply),
      do: {:usage, "mix pd.explain: --prompt and --apply cannot be used together"},
      else: :ok
  end

  defp check_exists(page) do
    if File.exists?(page), do: :ok, else: {:usage, "mix pd.explain: #{page} does not exist"}
  end

  # --- modes -----------------------------------------------------------------

  defp run_mode(page, opts) do
    with {:ok, html} <- read(page),
         {:ok, bundle} <- Explanation.read_bundle(html, page) |> lines_error() do
      cond do
        opts[:prompt] -> succeed(Explanation.prompt(bundle))
        file = opts[:apply] -> apply_explanation(page, html, bundle, file)
        true -> write_files(page, html, bundle)
      end
    else
      {:fail, lines} -> fail(lines)
    end
  end

  defp lines_error({:error, lines}), do: {:fail, lines}
  defp lines_error(ok), do: ok

  defp write_files(page, html, bundle) do
    if Explanation.explained?(html, bundle) do
      succeed(
        "#{page} is already explained " <>
          "(bundle #{bundle.hash}, prompt version #{Explanation.prompt_version()})\n"
      )
    else
      dir = Path.expand(page <> ".explain")
      bundle_path = Path.join(dir, "bundle.json")
      instructions_path = Path.join(dir, "instructions.md")

      with :ok <- mkdir(dir),
           :ok <- write(bundle_path, bundle.bytes),
           :ok <- write(instructions_path, Explanation.instructions()) do
        succeed(
          Enum.join(
            [
              bundle_path,
              instructions_path,
              "prompt version: #{Explanation.prompt_version()}",
              "bundle hash: #{bundle.hash}"
            ],
            "\n"
          ) <> "\n"
        )
      else
        {:fail, lines} -> fail(lines)
      end
    end
  end

  defp apply_explanation(page, html, bundle, file) do
    with :ok <- Explanation.check_earlier(html, page) |> lines_error(),
         {:ok, text} <- read_explanation(file),
         {:ok, explanation} <- Explanation.validate(text, bundle) |> lines_error(),
         :ok <- replace(page, Explanation.embed(html, bundle, explanation)) do
      succeed(
        "applied the explanation to #{page} " <>
          "(bundle #{bundle.hash}, prompt version #{Explanation.prompt_version()})\n"
      )
    else
      {:fail, lines} -> fail(lines)
    end
  end

  defp read_explanation("-") do
    case IO.read(:stdio, :eof) do
      text when is_binary(text) ->
        {:ok, text}

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:fail, ["mix pd.explain: cannot read standard input (#{:file.format_error(reason)})"]}
    end
  end

  defp read_explanation(file) do
    if File.exists?(file),
      do: read(file),
      else: {:fail, ["mix pd.explain: #{file} does not exist"]}
  end

  # --- files -----------------------------------------------------------------

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:fail, ["mix pd.explain: cannot read #{path} (#{:file.format_error(reason)})"]}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:fail, ["mix pd.explain: cannot create #{dir} (#{:file.format_error(reason)})"]}
    end
  end

  defp write(path, bytes) do
    case File.write(path, bytes) do
      :ok ->
        :ok

      {:error, reason} ->
        {:fail, ["mix pd.explain: cannot write #{path} (#{:file.format_error(reason)})"]}
    end
  end

  # Writes the new page to a temp file next to the old one and renames it over
  # the old one, so a reader sees the old page or the new page, never half of
  # one. The temp file is removed when any step fails.
  defp replace(page, bytes) do
    tmp =
      Path.join(
        Path.dirname(page),
        ".#{Path.basename(page)}.#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- write(tmp, bytes),
         :ok <- copy_mode(page, tmp),
         :ok <- rename(tmp, page) do
      :ok
    else
      {:fail, lines} ->
        File.rm(tmp)
        {:fail, lines}
    end
  end

  defp copy_mode(from, to) do
    with {:ok, %File.Stat{mode: mode}} <- File.stat(from),
         :ok <- File.chmod(to, mode) do
      :ok
    else
      {:error, reason} ->
        {:fail, ["mix pd.explain: cannot write #{to} (#{:file.format_error(reason)})"]}
    end
  end

  defp rename(tmp, page) do
    case File.rename(tmp, page) do
      :ok ->
        :ok

      {:error, reason} ->
        {:fail, ["mix pd.explain: cannot write #{page} (#{:file.format_error(reason)})"]}
    end
  end

  # --- output ----------------------------------------------------------------

  defp succeed(text) do
    IO.write(text)
    :ok
  end

  defp fail(lines) do
    Enum.each(lines, &IO.puts(:stderr, &1))
    :error
  end
end
