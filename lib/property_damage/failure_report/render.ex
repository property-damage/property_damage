defmodule PropertyDamage.FailureReport.Render do
  @moduledoc false
  # Prints a `PropertyDamage.FailureReport.Layout` (DR-056) as terminal text,
  # with or without ANSI color, and as markdown. The markdown is the plain
  # terminal text in markdown dress: the banner as a heading, the same
  # sections, and each section's body in a fenced block, byte for byte the
  # body the terminal prints without color. Every value goes through one
  # `inspect/2` call (DR-055 decision 10); color adds syntax colors there and
  # never changes a line's visible text, so a colored report with its ANSI
  # codes removed is the plain one.

  alias PropertyDamage.FailureReport.{Layout, SourceBadge}
  alias PropertyDamage.FailureReport.Layout.Section

  # The banner box's inner width, between its two borders.
  @box_width 70

  @inspect_opts [pretty: true, limit: :infinity, printable_limit: :infinity]

  # The width a value is fitted to, counted from the start of its line.
  @line_width 100

  # The column event lines start at: past every step's label.
  @event_indent 8

  @doc false
  @spec terminal(Layout.t(), boolean()) :: String.t()
  def terminal(%Layout{} = layout, color) do
    sections = Enum.map_join(layout.sections, "\n", &terminal_section(&1, color))
    banner(layout.banner, color) <> "\nSeed: #{layout.seed}\n\n" <> sections
  end

  @doc false
  @spec markdown(Layout.t()) :: String.t()
  def markdown(%Layout{} = layout) do
    sections = Enum.map_join(layout.sections, "\n", &markdown_section/1)
    markdown_banner(layout.banner) <> "\nSeed: #{layout.seed}\n\n" <> sections
  end

  defp terminal_section(%Section{} = section, color),
    do:
      paint("## " <> section.heading, [:bright, :yellow], color) <>
        "\n\n" <> body(section, color) <> "\n"

  defp markdown_section(%Section{} = section),
    do: "## #{section.heading}\n\n```#{section.fence}\n#{body(section, false)}\n```\n"

  # ==========================================================================
  # Banner
  # ==========================================================================

  defp banner(:bug_detected, color), do: box(["BUG DETECTED!"], :red, color)

  defp banner(:test_code_error, color),
    do: box(["TEST CODE ERROR", "(Not a bug in your SUT - fix your test!)"], :yellow, color)

  defp box(texts, tint, color) do
    rule = String.duplicate("═", @box_width)

    lines =
      ["╔" <> rule <> "╗"] ++ Enum.map(texts, &("║" <> center(&1) <> "║")) ++ ["╚" <> rule <> "╝"]

    Enum.map_join(lines, "", &(paint(&1, [:bright, tint], color) <> "\n"))
  end

  defp center(text) do
    left = div(@box_width - String.length(text), 2)
    String.pad_trailing(String.duplicate(" ", left) <> text, @box_width)
  end

  defp markdown_banner(:bug_detected), do: "# BUG DETECTED!\n"

  defp markdown_banner(:test_code_error),
    do: "# TEST CODE ERROR\n\nNot a bug in your SUT: fix your test.\n"

  # ==========================================================================
  # Lines
  # ==========================================================================

  defp body(%Section{lines: lines}, color) do
    column = field_column(lines)
    Enum.map_join(lines, "\n", &line(&1, column, color))
  end

  # The column every Failure value starts at: past the longest label.
  defp field_column(lines) do
    lines
    |> Enum.flat_map(fn
      {:field, label, _parts} -> [String.length(label) + 2]
      _other -> []
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp line(:blank, _column, _color), do: ""

  defp line({:field, label, parts}, column, color) do
    prefix = String.pad_trailing(label, column)
    paint(prefix, [:faint], color) <> hanging(parts(parts, color, column), column)
  end

  defp line({:header, text}, _column, color), do: paint(text, [:bright], color)

  defp line({:step, step}, _column, color) do
    marked? = step.outcome != nil
    lead = if marked?, do: "► ", else: "  "
    indent = String.duplicate("  ", step.depth)
    width = String.length(lead <> indent <> step.label <> " ")
    tint = if marked?, do: [:red], else: [:faint]

    [first | rest] = String.split(value(step.command, color, width), "\n")

    head =
      paint(lead, [:red], color and marked?) <>
        indent <>
        paint(step.label, tint, color) <>
        " " <> first <> note(step.note, color) <> mark(step.outcome, color)

    Enum.join([head | Enum.map(rest, &(String.duplicate(" ", width) <> &1))], "\n")
  end

  defp line({:event, event}, _column, color) do
    offset = "+" <> :erlang.float_to_binary(event.offset_ms / 1000, decimals: 2) <> "s"
    # The offset, a space, the five-column badge and a space precede the event.
    width = @event_indent + String.length(offset) + 7

    String.duplicate(" ", @event_indent) <>
      paint(offset, [:faint], color) <>
      " " <> badge(event.source, color) <> " " <> hanging(value(event.event, color, width), width)
  end

  defp line({:note, text}, _column, color), do: "  " <> paint(text, [:faint], color)

  defp line({:projection, name, applied}, _column, color) do
    paint(name, [:cyan], color) <> "   last applied: " <> (applied || "nothing")
  end

  defp line({:attribute, marker, key, value}, _column, color) do
    {sign, tint} =
      case marker do
        :same -> {"    ", nil}
        :minus -> {"  - ", :red}
        :plus -> {"  + ", :green}
      end

    key_text = key_text(key)
    # A diff line keeps its red or green and gets no syntax colors.
    text = value(value, color and tint == nil, 4 + String.length(key_text))
    [first | rest] = String.split(text, "\n")
    continuation = sign <> String.duplicate(" ", String.length(key_text))

    [sign <> key_text <> first | Enum.map(rest, &(continuation <> &1))]
    |> Enum.map_join("\n", &paint(&1, List.wrap(tint), color and tint != nil))
  end

  defp line({:comment, text}, _column, color), do: paint("# " <> text, [:faint], color)
  defp line({:code, text}, _column, color), do: paint(text, [:green], color)
  defp line({:text, text}, _column, _color), do: text

  defp key_text(nil), do: ""
  defp key_text(key) when is_atom(key), do: "#{key}: "
  defp key_text(key), do: inspect(key) <> " => "

  defp note(nil, _color), do: ""
  defp note(text, color), do: "  " <> paint(text, [:faint], color)

  defp mark(nil, _color), do: ""
  defp mark(outcome, color), do: "  " <> paint("◄── " <> outcome, [:red], color)

  # A command's event shows `event`; any other source its badge.
  defp badge(:command, color), do: paint("event", [:faint], color)

  defp badge(source, color) do
    text = SourceBadge.badge(source, false)
    padding = String.duplicate(" ", max(5 - String.length(text), 0))
    SourceBadge.badge(source, color) <> padding
  end

  # ==========================================================================
  # Values
  # ==========================================================================

  defp parts(parts, color, column) do
    Enum.map_join(parts, fn
      {:value, term} -> value(term, color, column)
      text when is_binary(text) -> text
    end)
  end

  # Every value prints in full, fitted to the line past `column`.
  defp value(term, color, column) do
    opts = [width: max(@line_width - column, 40)] ++ @inspect_opts

    if color,
      do: inspect(term, [syntax_colors: IO.ANSI.syntax_colors()] ++ opts),
      else: inspect(term, opts)
  end

  # The lines after a value's first continue at `column`.
  defp hanging(text, column) do
    [first | rest] = String.split(text, "\n")
    Enum.join([first | Enum.map(rest, &indent(&1, column))], "\n")
  end

  # A blank line inside a value stays empty rather than ending in spaces.
  defp indent("", _column), do: ""
  defp indent(line, column), do: String.duplicate(" ", column) <> line

  defp paint(text, _codes, false), do: text
  defp paint(text, [], true), do: text
  defp paint(text, codes, true), do: IO.ANSI.format([codes, text], true) |> IO.iodata_to_binary()
end
