defmodule PropertyDamage.FailureReport.Bundle.Redaction do
  @moduledoc """
  Replaces secret-shaped string literals in the source of a file that holds an
  adapter, so the JSON bundle of a failure page does not carry a password or a
  token that the adapter uses to reach the system under test.

  `redact/1` works by line. On every line that names a secret, it replaces
  each double-quoted string literal with `"[REDACTED]"` and counts the
  replacements. A line names a secret when an identifier outside any string
  or comment ends in `secret`, `password`, `token` or `key`, the last
  `_`-separated part of the identifier deciding: `@report_secret`,
  `password:`, `:admin_password` and `api_key` match, while `keys`,
  `keyword` and `monkey` do not.

  ## Limits

  The rule reads one line at a time, so it errs on both sides.

    * It replaces a harmless literal on a line that names a secret, such as
      the `"amount"` of `key: "amount"`.
    * It misses a secret that sits in a heredoc, a sigil (`~s(...)`), a
      charlist (`'...'`), a string that spans lines, or a line that names no
      secret word.

  Line numbers stay as they were: a replacement never adds or removes a
  newline.
  """

  @words ~w(secret password token key)
  @replacement ~S("[REDACTED]")
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*[?!]?/

  @rule "In a source file that holds an adapter, on every line that names a secret, password, token or key, " <>
          "each double-quoted string literal is replaced by \"[REDACTED]\"; " <>
          "heredocs, sigils and charlists are not scanned."

  @doc "The rule `redact/1` applies, in one sentence."
  @spec rule() :: String.t()
  def rule, do: @rule

  @doc """
  Returns `text` with the secret-shaped literals replaced, and the number of
  literals replaced.
  """
  @spec redact(String.t()) :: {String.t(), non_neg_integer()}
  def redact(text) when is_binary(text) do
    {lines, {_closer, count}} =
      text |> String.split("\n") |> Enum.map_reduce({nil, 0}, &redact_line/2)

    {Enum.join(lines, "\n"), count}
  end

  # Inside a heredoc the line passes unchanged until the closing delimiter.
  defp redact_line(line, {nil, count}) do
    {tokens, closer} = scan(line, [])

    if Enum.any?(tokens, &secret_word?/1) do
      {replaced, n} = replace_strings(tokens)
      {replaced, {closer, count + n}}
    else
      {Enum.map_join(tokens, &elem(&1, 1)), {closer, count}}
    end
  end

  defp redact_line(line, {closer, count}) do
    if line |> String.trim_leading() |> String.starts_with?(closer),
      do: {line, {nil, count}},
      else: {line, {closer, count}}
  end

  defp secret_word?({:word, word}) do
    last = word |> String.trim_trailing("?") |> String.trim_trailing("!") |> last_part()
    last in @words
  end

  defp secret_word?(_token), do: false

  defp last_part(word), do: word |> String.split("_") |> List.last()

  defp replace_strings(tokens) do
    {parts, count} =
      Enum.map_reduce(tokens, 0, fn
        {:string, _text}, count -> {@replacement, count + 1}
        {_kind, text}, count -> {text, count}
      end)

    {Enum.join(parts), count}
  end

  # Splits one line into `{:word, text}`, `{:string, text}` and `{:other,
  # text}` tokens, and returns the closing delimiter when the line opens a
  # heredoc.
  defp scan("", acc), do: {Enum.reverse(acc), nil}
  defp scan("#" <> _ = comment, acc), do: {Enum.reverse([{:other, comment} | acc]), nil}
  defp scan(~S(""") <> _ = rest, acc), do: {Enum.reverse([{:other, rest} | acc]), ~S(""")}
  defp scan("'''" <> _ = rest, acc), do: {Enum.reverse([{:other, rest} | acc]), "'''"}

  defp scan("~" <> <<letter, quotes::binary-size(3), _::binary>> = rest, acc)
       when letter in ?a..?z or letter in ?A..?Z do
    case quotes do
      ~S(""") -> {Enum.reverse([{:other, rest} | acc]), ~S(""")}
      "'''" -> {Enum.reverse([{:other, rest} | acc]), "'''"}
      _other -> scan_sigil(rest, acc)
    end
  end

  defp scan("~" <> <<letter, _::binary>> = rest, acc)
       when letter in ?a..?z or letter in ?A..?Z,
       do: scan_sigil(rest, acc)

  defp scan("\"" <> rest = text, acc) do
    case take(rest, "\"", "\"") do
      {literal, tail} -> scan(tail, [{:string, literal} | acc])
      :unterminated -> {Enum.reverse([{:other, text} | acc]), nil}
    end
  end

  defp scan("'" <> rest = text, acc) do
    case take(rest, "'", "'") do
      {literal, tail} -> scan(tail, [{:other, literal} | acc])
      :unterminated -> {Enum.reverse([{:other, text} | acc]), nil}
    end
  end

  defp scan(text, acc) do
    case Regex.run(@identifier, text) do
      [word] ->
        scan(binary_part(text, byte_size(word), byte_size(text) - byte_size(word)), [
          {:word, word} | acc
        ])

      nil ->
        scan_char(text, acc)
    end
  end

  defp scan_char(<<char::utf8, rest::binary>>, acc),
    do: scan(rest, [{:other, <<char::utf8>>} | acc])

  defp scan_char(<<byte, rest::binary>>, acc), do: scan(rest, [{:other, <<byte>>} | acc])

  # `~s(...)`: the letter, the opening delimiter, then the body up to the
  # closing delimiter. A sigil that does not close on the line is left as is.
  defp scan_sigil("~" <> <<letter, open::utf8, rest::binary>> = text, acc) do
    head = "~" <> <<letter, open::utf8>>

    case take(rest, closer(<<open::utf8>>), head) do
      {literal, tail} -> scan(tail, [{:other, literal} | acc])
      :unterminated -> {Enum.reverse([{:other, text} | acc]), nil}
    end
  end

  defp scan_sigil(text, acc), do: {Enum.reverse([{:other, text} | acc]), nil}

  defp closer("("), do: ")"
  defp closer("["), do: "]"
  defp closer("{"), do: "}"
  defp closer("<"), do: ">"
  defp closer(other), do: other

  # Takes text up to and including `closer`, honoring backslash escapes and
  # skipping over an interpolation, and returns it with the rest of the line.
  defp take("", _closer, _acc), do: :unterminated

  defp take("\\" <> <<char::utf8, rest::binary>>, closer, acc),
    do: take(rest, closer, acc <> "\\" <> <<char::utf8>>)

  defp take("\#{" <> rest, closer, acc), do: interpolation(rest, 1, closer, acc <> "\#{")

  defp take(text, closer, acc) do
    if String.starts_with?(text, closer) do
      {acc <> closer, binary_part(text, byte_size(closer), byte_size(text) - byte_size(closer))}
    else
      <<char, rest::binary>> = text
      take(rest, closer, acc <> <<char>>)
    end
  end

  defp interpolation("", _depth, _closer, _acc), do: :unterminated
  defp interpolation("}" <> rest, 1, closer, acc), do: take(rest, closer, acc <> "}")

  defp interpolation("}" <> rest, depth, closer, acc),
    do: interpolation(rest, depth - 1, closer, acc <> "}")

  defp interpolation("{" <> rest, depth, closer, acc),
    do: interpolation(rest, depth + 1, closer, acc <> "{")

  defp interpolation(<<char::utf8, rest::binary>>, depth, closer, acc),
    do: interpolation(rest, depth, closer, acc <> <<char::utf8>>)

  defp interpolation(<<byte, rest::binary>>, depth, closer, acc),
    do: interpolation(rest, depth, closer, acc <> <<byte>>)
end
