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

  A double-quoted identifier used as a map key reads as a bare identifier:
  `"api_key" =>` and `"password": ` match, `"keys" =>` does not. The key
  itself stays as written and is not counted; every other literal on the
  line is replaced. A bare `"token"` that is not a key names nothing.

  When a line that names a secret ends in `,`, `(`, `[` or `{`, the call
  continues on the next line, so the next line's double-quoted literals are
  replaced too. That reach is one line: it chains only when the next line
  names a secret itself.

  ## Limits

  The rule reads one line at a time, so it errs on both sides.

    * It replaces a harmless literal on a line that names a secret, such as
      the `"amount"` of `key: "amount"`.
    * It misses a secret that sits in a heredoc, a sigil (`~s(...)`), a
      charlist (`'...'`), a string that spans lines, a bare string such as
      a query string (`"?token=abc"`), a comment, a `?"` character literal,
      a camelCase name (`apiKey`), or a line that names no secret word and
      does not follow one that wraps.

  Line numbers stay as they were: a replacement never adds or removes a
  newline.
  """

  @words ~w(secret password token key)
  @replacement ~S("[REDACTED]")
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*[?!]?/
  @bare_identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/

  @rule "In a source file that holds an adapter, on every line that names a secret, password, token or key " <>
          "(a quoted map key included, kept as written) and on the next line when it ends in a comma or an opening bracket, " <>
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
    {lines, {_closer, count, _wrapped}} =
      text |> String.split("\n") |> Enum.map_reduce({nil, 0, false}, &redact_line/2)

    {Enum.join(lines, "\n"), count}
  end

  # Inside a heredoc the line passes unchanged until the closing delimiter.
  defp redact_line(line, {nil, count, wrapped}) do
    {tokens, closer} = scan(line, [])
    tokens = mark_keys(tokens)
    names_secret? = Enum.any?(tokens, &secret_word?/1)

    if names_secret? or wrapped do
      {replaced, n} = replace_strings(tokens)
      {replaced, {closer, count + n, names_secret? and closer == nil and opens_call?(line)}}
    else
      {Enum.map_join(tokens, &elem(&1, 1)), {closer, count, false}}
    end
  end

  defp redact_line(line, {closer, count, _wrapped}) do
    if line |> String.trim_leading() |> String.starts_with?(closer),
      do: {line, {nil, count, false}},
      else: {line, {closer, count, false}}
  end

  # A line that ends on a separator or an opening bracket continues on the
  # next line, where a formatter wraps the argument of a call.
  defp opens_call?(line),
    do: line |> String.trim_trailing() |> String.ends_with?([",", "(", "[", "{"])

  # A double-quoted identifier used as a map key (`"a" =>` or `"a": `) reads
  # as the bare identifier. It stays as written and is not counted.
  defp mark_keys(tokens), do: mark_keys(tokens, [])

  defp mark_keys([], acc), do: Enum.reverse(acc)

  defp mark_keys([{:string, literal} = token | rest], acc) do
    if key?(literal, rest),
      do: mark_keys(rest, [{:key, literal} | acc]),
      else: mark_keys(rest, [token | acc])
  end

  defp mark_keys([token | rest], acc), do: mark_keys(rest, [token | acc])

  defp key?(literal, rest) do
    inner = binary_part(literal, 1, byte_size(literal) - 2)
    after_key = Enum.map_join(rest, &elem(&1, 1))

    Regex.match?(@bare_identifier, inner) and
      (Regex.match?(~r/\A\s*=>/, after_key) or String.starts_with?(after_key, ": "))
  end

  defp secret_word?({:word, word}), do: secret_name?(word)

  defp secret_word?({:key, literal}),
    do: literal |> binary_part(1, byte_size(literal) - 2) |> secret_name?()

  defp secret_word?(_token), do: false

  defp secret_name?(word) do
    last = word |> String.trim_trailing("?") |> String.trim_trailing("!") |> last_part()
    last in @words
  end

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
