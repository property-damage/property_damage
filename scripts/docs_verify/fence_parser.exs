# Markdown fenced-code parser for the documentation-verification gate.
#
# Extracts every fenced code block in document order, records its language, the
# 1-based line number of the opening fence, its content, and whether the line
# IMMEDIATELY above the opener (no blank line between) is exactly the runnable
# marker HTML comment. Also tracks the nearest preceding ATX heading, used by the
# notebook runner to name a failing cell.
#
# Two further markers are read here. A `<!-- pd-example: <path> -->` line directly
# above a fence (or above its runnable marker) names the project file the fence
# holds; it lands in the fence's `example` field. A line
# `<!-- pd-doc-verify: include <guide> <path> -->` stands for the fence of <guide>
# that holds project file <path>: the parser emits it as a runnable fence of
# language "include" whose content is "<guide> <path>", and the document runner
# evaluates the named fence at that point of the document.
defmodule DocsVerify.FenceParser do
  @marker "<!-- pd-doc-verify: runnable -->"
  @include ~r/^<!-- pd-doc-verify: include (\S+) (\S+) -->$/
  @example ~r/^<!-- pd-example: (\S+) -->$/

  defmodule Fence do
    defstruct [:lang, :start_line, :content, :runnable, :heading, :example]
  end

  def marker, do: @marker

  @doc "Parse a markdown string into an ordered list of %Fence{}."
  def parse(source) when is_binary(source) do
    lines = String.split(source, "\n")
    walk(lines, 1, nil, [], nil, nil)
  end

  def parse_file(path) do
    path |> File.read!() |> parse()
  end

  # walk(remaining_lines, line_no, current_heading, acc, prev_line, line_before_prev)
  defp walk([], _n, _heading, acc, _prev, _prev2), do: Enum.reverse(acc)

  defp walk([line | rest], n, heading, acc, prev, prev2) do
    cond do
      fence_opener?(line) ->
        lang = fence_lang(line)
        runnable = String.trim(prev || "") == @marker
        example = example_path(prev, prev2, runnable)
        {content_lines, after_rest, consumed} = take_until_close(rest)

        fence = %Fence{
          lang: lang,
          start_line: n,
          content: Enum.join(content_lines, "\n"),
          runnable: runnable,
          heading: heading,
          example: example
        }

        # Advance line counter past the whole block: opener + content + closer.
        walk(after_rest, n + 1 + consumed, heading, [fence | acc], "", "")

      match = Regex.run(@include, String.trim(line)) ->
        [_, guide, path] = match

        fence = %Fence{
          lang: "include",
          start_line: n,
          content: guide <> " " <> path,
          runnable: true,
          heading: heading
        }

        walk(rest, n + 1, heading, [fence | acc], line, prev)

      heading?(line) ->
        walk(rest, n + 1, String.trim(line), acc, line, prev)

      true ->
        walk(rest, n + 1, heading, acc, line, prev)
    end
  end

  # The pd-example marker sits directly above the fence, or above its runnable marker.
  defp example_path(prev, prev2, runnable) do
    candidate = if runnable, do: prev2, else: prev

    case Regex.run(@example, String.trim(candidate || "")) do
      [_, path] -> path
      nil -> nil
    end
  end

  # A code fence opener/closer starts with three backticks (allowing indentation).
  defp fence_opener?(line), do: Regex.match?(~r/^\s*```/, line)

  defp fence_lang(line) do
    line
    |> String.replace(~r/^\s*```/, "")
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> to_string()
  end

  # A closer is a line whose trimmed content is exactly the backtick fence.
  defp fence_closer?(line), do: Regex.match?(~r/^\s*```\s*$/, line)

  defp heading?(line), do: Regex.match?(~r/^\#{1,6}\s+\S/, line)

  # Returns {content_lines, lines_after_closer, lines_consumed_including_closer}.
  defp take_until_close(lines), do: take_until_close(lines, [], 0)

  defp take_until_close([], content, consumed),
    do: {Enum.reverse(content), [], consumed}

  defp take_until_close([line | rest], content, consumed) do
    if fence_closer?(line) do
      {Enum.reverse(content), rest, consumed + 1}
    else
      take_until_close(rest, [line | content], consumed + 1)
    end
  end
end
