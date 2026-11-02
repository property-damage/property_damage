defmodule Mix.Tasks.Pd.Explain do
  @moduledoc """
  Prints the prompt for a failure page, and puts a model's explanation back into it.

  A failure page written by PropertyDamage carries a machine-readable copy of
  the failure, its bundle. This task gives you that bundle together with
  instructions for writing an explanation, and it checks an explanation you
  bring back before it adds the explanation to the page. The task has no model
  built in: you, or an agent working for you, run the prompt and produce the
  explanation, or you name a command with `--with` and the task runs it for
  you.

  It reads one page and loads no project code.

  ## Usage

      mix pd.explain PAGE
      mix pd.explain PAGE --prompt
      mix pd.explain PAGE --apply FILE
      mix pd.explain PAGE --apply -
      mix pd.explain PAGE --with CMD [--attempts N] [--timeout T]

  ## Modes

  Without an option, the task writes the directory `PAGE.explain` (created if
  missing) with two files, `bundle.json` and `instructions.md`, and prints their
  absolute paths, the prompt version and the bundle hash, one per line. It
  overwrites those two files and removes nothing else in the directory. It
  refuses to write through either file when that file is a symbolic link.
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
  The task reads the explanation as bytes, from standard input as from a file,
  and ignores a leading byte-order mark. It refuses a page that is a symbolic
  link or is read-only, and says so on one line, so it never replaces a link
  with a file or overwrites a page you protected.

  With `--with CMD`, the task runs the whole loop. It runs `CMD` with `sh -c`,
  sends the same text `--prompt` prints to its standard input and closes the
  input, and reads the answer from its standard output. The answer then goes
  through the checks of `--apply`, and a page that passes is written as `--apply`
  writes it. Standard error of `CMD` shows on your terminal as it is. `--with`
  cannot be combined with `--prompt` or `--apply`. For example:

      mix pd.explain PAGE --with "my-llm-cli --json"

  `CMD` must print the explanation as a JSON object, either as its whole output
  or as the last fenced block whose info string is exactly `json` (a line of
  three or more backticks followed by `json`, closed by a line of at least as
  many backticks). `CMD` must exit with 0; the output of a command that exits
  with another status is not read.

  An attempt fails when `CMD` exits with a status other than 0, runs longer than
  the timeout, prints no JSON, or prints an explanation that fails the checks.
  After a failed attempt, the task prints `attempt N/M: ` and the reason to
  standard error, then runs `CMD` again. The new input is the same prompt, then
  the heading `## Your previous answer` with the previous output as it was, then
  the heading `## Errors` with the error lines, one per line. After the last
  failed attempt the task prints that attempt's error lines and says that the
  page is unchanged. The page changes only when an attempt passes.

  `--attempts N` sets the number of attempts, 3 by default. `--timeout T` sets
  how long one attempt may run, `10m` by default; write it as `<n>s`, `<n>m` or
  a number of seconds. When the timeout passes, the task kills `CMD` and every
  process it started. Both options need `--with`, or the config below.

  To run a command without typing it, set it in the config of your project:

      config :property_damage, explain_with: "my-llm-cli --json"

  When that value is a non-empty string and you give neither `--prompt` nor
  `--apply` nor `--with`, the task prints
  `using the command from config :property_damage, :explain_with` to standard
  error and behaves as if you had passed `--with` with that command.

  `--with` runs `CMD` on every call, and the command may cost money each time.
  Put `--with` in a CI job only if you accept that the job runs the command, and
  pays for it, on every failure.

  ## Exit codes

  The task exits with 0 when it did what was asked, including when the page is
  already explained. It exits with 1 on a usage error, on a page it cannot read
  (no bundle, more than one bundle, a bundle that is not JSON, a bundle format
  this version does not read), on an explanation that fails a check, and when
  `--with` finds no valid explanation in its attempts. Every error goes to
  standard error, and standard output stays empty.

  ## Checks on an explanation

  The explanation must have the shape the instructions describe, and any
  `bundle_hash` it names must be the page's. Every id it cites must exist in
  the bundle, and a hypothesis may not cite a context item whose description is
  missing. See `PropertyDamage.FailureReport.Explanation` for the rules.
  """

  use Mix.Task

  alias PropertyDamage.FailureReport.CommandRunner
  alias PropertyDamage.FailureReport.Explanation

  @shortdoc "Print the prompt for a failure page, or apply an explanation to it"

  @default_attempts 3
  @default_timeout_seconds 600

  @usage "usage: mix pd.explain PAGE " <>
           "[--prompt | --apply FILE|- | --with CMD [--attempts N] [--timeout T]]"

  @config_notice "using the command from config :property_damage, :explain_with"

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
      OptionParser.parse(args,
        strict: [
          prompt: :boolean,
          apply: :string,
          with: :string,
          attempts: :integer,
          timeout: :string
        ]
      )

    with :ok <- check_options(invalid),
         {:ok, page} <- check_page_count(argv),
         :ok <- check_modes(opts),
         :ok <- check_values(opts),
         {:ok, mode} <- resolve_mode(opts),
         :ok <- check_exists(page) do
      run_mode(page, mode)
    else
      {:usage, problem} -> fail([problem, @usage])
    end
  end

  defp halt_on_error(:ok), do: :ok
  defp halt_on_error(:error), do: System.halt(1)

  # --- usage -----------------------------------------------------------------

  defp check_options([]), do: :ok

  defp check_options([{switch, nil} | _])
       when switch in ["--apply", "--with", "--attempts", "--timeout"],
       do: {:usage, "mix pd.explain: #{switch} needs a value"}

  defp check_options([{"--attempts", value} | _]), do: {:usage, attempts_problem(value)}
  defp check_options([{"--timeout", value} | _]), do: {:usage, timeout_problem(value)}

  defp check_options([{"--prompt", value} | _]),
    do: {:usage, "mix pd.explain: --prompt takes no value, got #{value}"}

  defp check_options([{switch, _value} | _]),
    do: {:usage, "mix pd.explain: unknown option #{switch}"}

  defp check_page_count([page]), do: {:ok, page}
  defp check_page_count([]), do: {:usage, "mix pd.explain: no PAGE given"}
  defp check_page_count(_several), do: {:usage, "mix pd.explain: more than one PAGE given"}

  defp check_modes(opts) do
    cond do
      opts[:prompt] && Keyword.has_key?(opts, :apply) ->
        {:usage, "mix pd.explain: --prompt and --apply cannot be used together"}

      Keyword.has_key?(opts, :with) && opts[:prompt] ->
        {:usage, "mix pd.explain: --with and --prompt cannot be used together"}

      Keyword.has_key?(opts, :with) && Keyword.has_key?(opts, :apply) ->
        {:usage, "mix pd.explain: --with and --apply cannot be used together"}

      true ->
        :ok
    end
  end

  defp check_values(opts) do
    if opts[:apply] == "",
      do: {:usage, "mix pd.explain: --apply needs a value"},
      else: :ok
  end

  # Settles what the task does. A `--with` command wins over the config; the
  # other mode flags win over both.
  defp resolve_mode(opts) do
    cond do
      Keyword.has_key?(opts, :with) -> with_mode(opts[:with], false, opts)
      opts[:prompt] -> no_run_options(:prompt, opts)
      Keyword.has_key?(opts, :apply) -> no_run_options({:apply, opts[:apply]}, opts)
      command = configured_command() -> with_mode(command, true, opts)
      true -> no_run_options(:default, opts)
    end
  end

  defp with_mode("", _from_config, _opts), do: {:usage, "mix pd.explain: --with needs a value"}

  defp with_mode(command, from_config, opts) do
    with {:ok, attempts} <- attempts(opts[:attempts]),
         {:ok, seconds} <- timeout_seconds(opts[:timeout]) do
      {:ok, {:with, %{command: command, attempts: attempts, seconds: seconds}, from_config}}
    end
  end

  defp no_run_options(mode, opts) do
    cond do
      Keyword.has_key?(opts, :attempts) -> {:usage, "mix pd.explain: --attempts needs --with"}
      Keyword.has_key?(opts, :timeout) -> {:usage, "mix pd.explain: --timeout needs --with"}
      true -> {:ok, mode}
    end
  end

  # Mix reads the project config in the `app.config` task, which has run before
  # this task in a normal `mix` call and does nothing when run again.
  defp configured_command do
    Mix.Task.run("app.config")

    case Application.get_env(:property_damage, :explain_with) do
      command when is_binary(command) and command != "" -> command
      _other -> nil
    end
  end

  defp attempts(nil), do: {:ok, @default_attempts}
  defp attempts(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp attempts(n), do: {:usage, attempts_problem(n)}

  defp attempts_problem(value),
    do: "mix pd.explain: --attempts must be a positive integer, got #{value}"

  defp timeout_seconds(nil), do: {:ok, @default_timeout_seconds}

  defp timeout_seconds(text) do
    with [_all, digits, unit] <- Regex.run(~r/\A([0-9]+)([sm]?)\z/, text),
         seconds when seconds > 0 <- String.to_integer(digits) * unit_seconds(unit) do
      {:ok, seconds}
    else
      _invalid -> {:usage, timeout_problem(text)}
    end
  end

  defp unit_seconds("m"), do: 60
  defp unit_seconds(_seconds), do: 1

  defp timeout_problem(value),
    do: "mix pd.explain: --timeout must be <n>s, <n>m or a number of seconds, got #{value}"

  defp show_seconds(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp show_seconds(seconds), do: "#{seconds}s"

  defp check_exists(page) do
    if File.exists?(page), do: :ok, else: {:usage, "mix pd.explain: #{page} does not exist"}
  end

  # --- modes -----------------------------------------------------------------

  defp run_mode(page, mode) do
    if match?({:with, _run, true}, mode), do: IO.puts(:stderr, @config_notice)

    with {:ok, html} <- read(page),
         {:ok, bundle} <- Explanation.read_bundle(html, page) |> lines_error() do
      case mode do
        :prompt -> succeed(Explanation.prompt(bundle))
        {:apply, file} -> apply_explanation(page, html, bundle, file)
        {:with, run, _from_config} -> explain_with(page, html, bundle, run)
        :default -> write_files(page, html, bundle)
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
           :ok <- refuse_links([bundle_path, instructions_path]),
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
    with :ok <- check_replaceable(page),
         :ok <- Explanation.check_earlier(html, page) |> lines_error(),
         {:ok, text} <- read_explanation(file),
         {:ok, explanation} <- Explanation.validate(text, bundle) |> lines_error(),
         :ok <- replace(page, Explanation.embed(html, bundle, explanation)) do
      succeed(applied_line(page, bundle))
    else
      {:fail, lines} -> fail(lines)
    end
  end

  defp applied_line(page, bundle) do
    "applied the explanation to #{page} " <>
      "(bundle #{bundle.hash}, prompt version #{Explanation.prompt_version()})\n"
  end

  # --- --with ----------------------------------------------------------------

  # Runs the command up to `run.attempts` times. Every answer goes through
  # `Explanation.validate/2` and `Explanation.embed/3`, as `--apply` does.
  defp explain_with(page, html, bundle, run) do
    with :ok <- check_replaceable(page),
         :ok <- Explanation.check_earlier(html, page) |> lines_error() do
      prompt = Explanation.prompt(bundle)

      attempt(
        1,
        Map.merge(run, %{page: page, html: html, bundle: bundle, prompt: prompt}),
        prompt
      )
    else
      {:fail, lines} -> fail(lines)
    end
  end

  defp attempt(n, run, input) do
    case run_once(run, input) do
      {:ok, explanation} ->
        case replace(run.page, Explanation.embed(run.html, run.bundle, explanation)) do
          :ok -> succeed(applied_line(run.page, run.bundle))
          {:fail, lines} -> fail(lines)
        end

      {:failed, output, failure} when n < run.attempts ->
        IO.puts(:stderr, "attempt #{n}/#{run.attempts}: #{failure.reason}")
        attempt(n + 1, run, retry_input(run.prompt, output, failure.lines))

      {:failed, _output, failure} ->
        fail(
          failure.shown ++
            [
              "mix pd.explain: no valid explanation after " <>
                "#{plural(run.attempts, "attempt")}; the page is unchanged"
            ]
        )

      {:fail, lines} ->
        fail(lines)
    end
  end

  defp retry_input(prompt, output, lines) do
    prompt <>
      "\n\n## Your previous answer\n\n" <> output <> "\n\n## Errors\n\n" <> Enum.join(lines, "\n")
  end

  defp run_once(run, input) do
    case CommandRunner.run(run.command, input, run.seconds * 1000) do
      {:ok, output} -> check_answer(output, run.bundle)
      {:exit, status, output} -> failed(output, "command exited with status #{status}")
      {:timeout, output} -> failed(output, "timed out after #{show_seconds(run.seconds)}")
      {:error, reason} -> {:fail, ["mix pd.explain: " <> reason]}
    end
  end

  defp check_answer(output, bundle) do
    case answer_text(output) do
      nil ->
        failed(output, "no JSON found in the command's output")

      text ->
        case Explanation.validate(text, bundle) do
          {:ok, explanation} ->
            {:ok, explanation}

          {:error, lines} ->
            reason = "#{plural(length(lines), "error")} in the explanation"
            {:failed, output, %{reason: reason, lines: lines, shown: lines}}
        end
    end
  end

  defp failed(output, reason),
    do:
      {:failed, output, %{reason: reason, lines: [reason], shown: ["mix pd.explain: " <> reason]}}

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  # The whole output when it is a JSON object, else the body of the last fenced
  # block whose info string is exactly `json`, else nil.
  defp answer_text(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, %{}} -> trimmed
      _other -> last_json_block(output)
    end
  end

  defp last_json_block(output) do
    {_open, last} =
      output |> String.split(~r/\r?\n/) |> Enum.reduce({nil, nil}, &scan_fence_line/2)

    last
  end

  # State is the open fence (its backtick count, whether it is a json fence and
  # its lines so far) and the body of the last json block closed so far.
  defp scan_fence_line(line, {nil, last}) do
    case Regex.run(~r/\A {0,3}(`{3,})([^`]*)\z/, line) do
      [_all, ticks, info] -> {{String.length(ticks), String.trim(info) == "json", []}, last}
      nil -> {nil, last}
    end
  end

  defp scan_fence_line(line, {{size, json?, body}, last}) do
    if closes_fence?(line, size) do
      {nil, if(json?, do: body |> Enum.reverse() |> Enum.join("\n"), else: last)}
    else
      {{size, json?, [line | body]}, last}
    end
  end

  defp closes_fence?(line, size) do
    case Regex.run(~r/\A {0,3}(`{3,})[ \t]*\z/, line) do
      [_all, ticks] -> String.length(ticks) >= size
      nil -> false
    end
  end

  defp read_explanation("-") do
    case IO.binread(:stdio, :eof) do
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

    with :ok <- write_temp(tmp, page, bytes),
         :ok <- copy_mode(page, tmp),
         :ok <- rename(tmp, page) do
      :ok
    else
      {:fail, lines} ->
        File.rm(tmp)
        {:fail, lines}
    end
  end

  # Failures name the page, never the temp file, which the reader did not ask
  # for and which no longer exists once the task reports the failure.
  defp write_temp(tmp, page, bytes) do
    case File.write(tmp, bytes) do
      :ok -> :ok
      {:error, reason} -> {:fail, [cannot_write(page, reason)]}
    end
  end

  defp copy_mode(page, tmp) do
    with {:ok, %File.Stat{mode: mode}} <- File.stat(page),
         :ok <- File.chmod(tmp, mode) do
      :ok
    else
      {:error, reason} -> {:fail, [cannot_write(page, reason)]}
    end
  end

  defp cannot_write(path, reason),
    do: "mix pd.explain: cannot write #{path} (#{:file.format_error(reason)})"

  # A symbolic link would be replaced by a regular file, and a read-only page
  # is one its owner chose to protect, so the task changes neither.
  defp check_replaceable(page) do
    case File.lstat(page) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:fail, ["mix pd.explain: #{page} is a symbolic link; refusing to replace it"]}

      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o200) == 0 ->
        {:fail, ["mix pd.explain: #{page} is read-only; refusing to replace it"]}

      _readable_and_writable ->
        :ok
    end
  end

  # Writing to a symbolic link changes the file it points to, which may lie
  # outside the directory of the page.
  defp refuse_links(paths) do
    case Enum.find(paths, &match?({:ok, %File.Stat{type: :symlink}}, File.lstat(&1))) do
      nil ->
        :ok

      link ->
        {:fail, ["mix pd.explain: #{link} is a symbolic link; refusing to write through it"]}
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
