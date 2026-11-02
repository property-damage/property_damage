defmodule PropertyDamage.FailureReport.HTML do
  @moduledoc """
  The failure report as one self-contained HTML page, and a directory of such
  pages browsed through one index page.

  The page holds the report's terminal text, without color, and a viewer that
  reads it: one column per target, steps that unfold to their log lines and
  events, repeated log lines collated, the detail under a log line folded by
  its indentation, and the events of each step compared across targets. The
  text is the same layout `PropertyDamage.ExUnit.format_failure/2` prints, so
  the page and the terminal never disagree, and the same tag filter applies
  (the report's `log:` option, or `PD_LOG`). The page loads nothing from the
  network and opens from disk.

  A second script tag, `pd-bundle`, holds a JSON copy of the failure's
  structure, docs and sources for other programs to read (see
  `PropertyDamage.FailureReport.Bundle`). The viewer reads it only to resolve
  the citations of an explanation the page carries.

  Three ways to get a page:

    * `render/1` returns it as a string.
    * `write/2` writes it into a directory and refreshes that directory's
      `index.html`.
    * The run option `report_html: dir`, or the environment variable
      `PD_REPORT_HTML=dir` for every run of a test suite, makes each failing
      run call `write/2`.

  ## The index page

  `index.html` shows one report at a time, with buttons to move between
  them. The left and right arrow keys also move between reports while the
  index page has focus; a browser may keep the key presses inside the report
  frame, so the buttons are the dependable way. Inside a report with several
  targets, the arrow keys first move the selected line between targets.

  `write_index/1` rebuilds the index from the pages in the directory; call it
  after runs in separate processes write into one directory, since two
  writers can each list the directory before the other's page lands.
  """

  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.{Bundle, Formatter}

  @viewer_path Path.expand("../../../priv/failure_report/viewer.html", __DIR__)
  @index_path Path.expand("../../../priv/failure_report/index.html", __DIR__)
  @external_resource @viewer_path
  @external_resource @index_path
  @viewer File.read!(@viewer_path)
  @index File.read!(@index_path)

  @env "PD_REPORT_HTML"

  @doc "The report as one HTML page."
  @spec render(FailureReport.t()) :: String.t()
  def render(%FailureReport{} = report) do
    text = Formatter.format(report, :terminal, color: false)

    # One pass over the template, so text in a replacement that looks like a
    # placeholder is never replaced itself.
    String.replace(
      @viewer,
      ["__PD_TITLE__", "__PD_REPORT_JSON__", "__PD_BUNDLE_JSON__"],
      fn
        "__PD_TITLE__" -> escape(title(report))
        "__PD_REPORT_JSON__" -> Jason.encode!(text, escape: :html_safe)
        "__PD_BUNDLE_JSON__" -> Jason.encode!(Bundle.build(report, []), escape: :html_safe)
      end
    )
  end

  @doc """
  Writes the report's page into `dir`, created when missing, and rebuilds
  `dir/index.html`. The file is named after the model, the failing target,
  the failure kind and the seed, so a later failure of the same run replaces
  it.
  """
  @spec write(FailureReport.t(), Path.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def write(%FailureReport{} = report, dir) do
    path = Path.join(dir, file_name(report))

    with :ok <- File.mkdir_p(dir),
         :ok <- write_atomically(path, render(report)),
         {:ok, _index} <- write_index(dir) do
      {:ok, path}
    end
  end

  @doc """
  Rebuilds `dir/index.html` from the report pages in `dir`, in file name
  order.
  """
  @spec write_index(Path.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def write_index(dir) do
    with {:ok, files} <- File.ls(dir) do
      entries =
        files
        |> Enum.filter(&(Path.extname(&1) == ".html" and &1 != "index.html"))
        |> Enum.sort()
        |> Enum.flat_map(fn file ->
          case read_title(Path.join(dir, file)) do
            nil -> []
            title -> [%{file: file, title: title}]
          end
        end)

      path = Path.join(dir, "index.html")

      page =
        String.replace(@index, "__PD_REPORTS_JSON__", Jason.encode!(entries, escape: :html_safe))

      with :ok <- write_atomically(path, page), do: {:ok, path}
    end
  end

  @doc """
  The directory failing runs write their pages into: `PD_REPORT_HTML` when
  set and not blank, else the run's `report_html:` option, else `nil`.
  """
  @spec dir(Path.t() | false | nil) :: Path.t() | nil
  def dir(option) do
    case System.get_env(@env) do
      nil -> option_dir(option)
      text -> if String.trim(text) == "", do: option_dir(option), else: text
    end
  end

  defp option_dir(dir) when is_binary(dir), do: dir
  defp option_dir(_none), do: nil

  # The banner's facts, for the browser tab and the index.
  defp title(%FailureReport{} = report) do
    [
      report.model && inspect(report.model),
      target(report),
      report.kind && to_string(report.kind),
      report.seed && "seed #{report.seed}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The failing target's name, after its adapter when the name does not say
  # it: two suites can run one model under one target name against different
  # adapters, such as a mock and the real system.
  defp target(%FailureReport{variant: nil}), do: nil

  defp target(%FailureReport{variant: %{index: index, name: name}, targets: targets}) do
    case Enum.at(targets || [], index) do
      {adapter, _entry} when is_atom(adapter) ->
        short = adapter |> Module.split() |> List.last()
        if short == name, do: name, else: "#{short}.#{name}"

      _ ->
        name
    end
  end

  defp file_name(%FailureReport{} = report) do
    stem =
      [
        report.model && inspect(report.model),
        target(report),
        report.kind && to_string(report.kind),
        report.seed && "seed#{report.seed}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("-")
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")

    if stem == "", do: "failure_report.html", else: stem <> ".html"
  end

  # A page whose title cannot be read is not a report page and stays out of
  # the index.
  defp read_title(path) do
    with {:ok, html} <- File.read(path),
         [_, title] <- Regex.run(~r{<title>(.*?)</title>}s, html) do
      unescape(title)
    else
      _ -> nil
    end
  end

  # Another process may read the file while it is written: it sees the old
  # file or the new one, never half of one.
  defp write_atomically(path, content) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp, content) do
      File.rename(tmp, path)
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
  end
end
