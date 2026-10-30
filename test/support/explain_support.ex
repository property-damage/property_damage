defmodule PropertyDamage.Test.ExplainSupport do
  @moduledoc false
  # Helpers for the tests of `mix pd.explain` and the explanation module.
  #
  # The task and the module are reached through `task/0` and `explanation/0`,
  # which fail the calling test when the module does not exist and hand it
  # back in a variable, so a test file compiles whether or not the module
  # exists.
  #
  # The page readers (`bundle_bytes/1`, `explanation_tags/1`, `expected_page/2`)
  # cut bytes out of the page with plain string functions and no help from the
  # code under test, so a test compares what the task did with what the page
  # says it should be.
  #
  # The fixtures live in `test/fixtures/explain/`. A test copies a fixture into
  # its own tmp dir before it runs the task, and never writes into the tree.

  import ExUnit.Assertions
  import ExUnit.CaptureIO

  @fixtures Path.expand("../fixtures/explain", __DIR__)
  @bundle_open ~s(<script type="application/json" id="pd-bundle">)
  @explanation_open ~s(<script type="application/json" id="pd-explanation">)
  @close "</script>"

  # The module prefix of the system the fixture page was written from.
  @prefix "PropertyDamage.Test.Bundle2009281_3459"

  @doc "The usage line every usage error prints last."
  def usage_line,
    do:
      "usage: mix pd.explain PAGE " <>
        "[--prompt | --apply FILE|- | --with CMD [--attempts N] [--timeout T]]"

  @doc "The module name of `name` in the system the fixture page describes."
  def mod(name), do: @prefix <> "." <> name

  @doc "The task module; fails the test when it does not exist."
  def task, do: loaded!(Module.concat(["Mix", "Tasks", "Pd", "Explain"]))

  @doc "The explanation module; fails the test when it does not exist."
  def explanation,
    do: loaded!(Module.concat(["PropertyDamage", "FailureReport", "Explanation"]))

  @doc "The command runner behind `--with`; fails the test when it does not exist."
  def runner, do: loaded!(Module.concat(["PropertyDamage", "FailureReport", "CommandRunner"]))

  @doc "`Explanation.instructions/0`."
  def instructions do
    mod = explanation()

    assert function_exported?(mod, :instructions, 0),
           "#{inspect(mod)}.instructions/0 is not defined"

    mod.instructions()
  end

  @doc "`Explanation.prompt_version/0`."
  def prompt_version do
    mod = explanation()

    assert function_exported?(mod, :prompt_version, 0),
           "#{inspect(mod)}.prompt_version/0 is not defined"

    mod.prompt_version()
  end

  defp loaded!(module) do
    assert Code.ensure_loaded?(module), "the module #{inspect(module)} does not exist"
    module
  end

  # ==========================================================================
  # Running the task
  # ==========================================================================

  @doc """
  Runs `exec/1` of the task with `args` in this process.

  Returns `%{result: :ok | :error, stdout: binary, stderr: binary}`. Pass
  `input:` to supply stdin as text, or `binary_input:` to supply stdin as raw
  bytes that the task reads without any decoding. The caller must not run
  async: capturing stderr replaces a process that every test shares.
  """
  def exec(args, opts \\ []) do
    mod = task()
    assert function_exported?(mod, :exec, 1), "#{inspect(mod)}.exec/1 is not defined"
    parent = self()
    ref = make_ref()
    input = Keyword.get(opts, :input)
    binary_input = Keyword.get(opts, :binary_input)

    run = fn -> send(parent, {ref, :result, mod.exec(args)}) end

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          cond do
            binary_input ->
              capture_io(
                :stdio,
                [input: binary_input, encoding: :latin1, capture_prompt: false],
                run
              )

            input ->
              capture_io(:stdio, [input: input, capture_prompt: false], run)

            true ->
              capture_io(run)
          end

        send(parent, {ref, :stdout, stdout})
      end)

    assert_received {^ref, :result, result}
    assert_received {^ref, :stdout, stdout}
    %{result: result, stdout: stdout, stderr: stderr}
  end

  @doc """
  Runs `--apply` on the explanation `spec` against the page at `page`.

  `spec` is a fixture name, `{:raw, text}` or a map, which is written as JSON
  to a file in the page's directory under a name no test page uses.
  """
  def apply_to(page, spec) do
    file = explanation_file(Path.dirname(page), spec)
    exec([page, "--apply", file])
  end

  @doc "Writes the explanation `spec` to a file next to the page and returns its path."
  def explanation_file(dir, spec) do
    path = Path.join(dir, "input_explanation.json")

    text =
      case spec do
        name when is_binary(name) -> File.read!(Path.join(@fixtures, name))
        {:raw, text} -> text
        map when is_map(map) -> Jason.encode!(map)
      end

    File.write!(path, text)
    path
  end

  @doc "The lines of a stream's output, without the final newline."
  def lines(output) do
    assert output == "" or String.ends_with?(output, "\n"),
           "the output must end with a newline: #{inspect(output)}"

    String.split(output, "\n", trim: true)
  end

  # ==========================================================================
  # Fixtures
  # ==========================================================================

  @doc "The path of a committed fixture."
  def fixture_path(name), do: Path.join(@fixtures, name)

  @doc "The bytes of a committed fixture."
  def fixture(name), do: File.read!(fixture_path(name))

  @doc "A committed explanation, decoded."
  def explanation_fixture(name), do: name |> fixture() |> Jason.decode!()

  @doc "Copies the fixture into `dir` (under `as`, default the fixture's name); returns the path."
  def copy(dir, name, as \\ nil) do
    path = Path.join(dir, as || name)
    File.write!(path, fixture(name))
    path
  end

  @doc "Writes `bytes` to `name` in `dir`; returns the path."
  def write(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  # ==========================================================================
  # Reading pages
  # ==========================================================================

  @doc "The bytes between the pd-bundle tag and the first `</script>` after it."
  def bundle_bytes(html) do
    [_before, rest] = String.split(html, @bundle_open, parts: 2)
    [bytes, _after] = String.split(rest, @close, parts: 2)
    bytes
  end

  @doc "The lowercase hex SHA-256 of `bytes`."
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "The bundle hash of a page, cut out of the page itself."
  def bundle_hash(html), do: html |> bundle_bytes() |> sha256()

  @doc "The bundle of a page, decoded."
  def bundle(html), do: html |> bundle_bytes() |> Jason.decode!()

  @doc "The texts of every pd-explanation tag of the page, in page order."
  def explanation_tags(html) do
    html
    |> String.split(@explanation_open)
    |> tl()
    |> Enum.map(fn rest -> rest |> String.split(@close, parts: 2) |> hd() end)
  end

  @doc "How many tags of `id` the page declares."
  def tag_count(html, id), do: html |> String.split(~s(id="#{id}")) |> length() |> Kernel.-(1)

  @doc "The number of `</script>` closings in the page."
  def close_count(html), do: html |> String.split(@close) |> length() |> Kernel.-(1)

  @doc "The tag text of an explanation tag holding `json`."
  def tag(json), do: @explanation_open <> json <> @close

  @doc "The page with every pd-explanation tag cut out, byte for byte."
  def strip_explanations(html) do
    case String.split(html, @explanation_open, parts: 2) do
      [_only] ->
        html

      [before, rest] ->
        [_json, after_tag] = String.split(rest, @close, parts: 2)
        strip_explanations(before <> after_tag)
    end
  end

  @doc "The page with an explanation tag holding `json` right after the bundle's closing tag."
  def with_tag_after_bundle(html, json) do
    [head, rest] = String.split(html, @bundle_open, parts: 2)
    [bytes, tail] = String.split(rest, @close, parts: 2)
    head <> @bundle_open <> bytes <> @close <> tag(json) <> tail
  end

  @doc """
  The page the task must write for `original` and the tag text `json`: the old
  explanation tags cut out, then the new tag right after the bundle's closing
  tag.
  """
  def expected_page(original, json),
    do: original |> strip_explanations() |> with_tag_after_bundle(json)

  @doc "The page with `extra` inserted before its closing body tag."
  def with_text_before_body_end(html, extra) do
    [head, tail] = String.split(html, "</body>", parts: 2)
    head <> extra <> "</body>" <> tail
  end

  @doc "The sorted names of every file under `dir`, relative to it."
  def tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  # ==========================================================================
  # Mutating an explanation
  # ==========================================================================

  @doc "Removes `key` from the map at `path`."
  def drop(map, path, key), do: update_in(map, path, &Map.delete(&1, key))
end
