defmodule PropertyDamage.Next.Journal.Atoms do
  @moduledoc false
  # Reads the atoms that a binary in external term format names, without
  # creating any. Decoding with `:safe` refuses a binary that names an atom
  # this VM does not know, and refuses a binary that is not a term in the same
  # way; this scan tells the two apart so the refusal can say which it is.

  @doc """
  The names of the atoms in `binary` that this VM does not know.

  Returns `{:ok, names}` when `binary` is one whole term in external term
  format whose outer term is a three-element tuple tagged with the atom
  `format`, and `:error` for any other binary.
  """
  @spec unknown(binary(), atom()) :: {:ok, [String.t()]} | :error
  def unknown(binary, format) when is_binary(binary) and is_atom(format) do
    with {:ok, data} <- payload(binary),
         true <- tagged?(data, Atom.to_string(format)),
         {:ok, <<>>, names} <- term(data, []) do
      {:ok, names |> Enum.uniq() |> Enum.reject(&known?/1)}
    else
      _ -> :error
    end
  end

  defp payload(<<131, 80, size::32, compressed::binary>>) do
    case :zlib.uncompress(compressed) do
      data when byte_size(data) == size -> {:ok, data}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp payload(<<131, data::binary>>), do: {:ok, data}
  defp payload(_), do: :error

  defp tagged?(<<104, 3, tag, _::binary>> = data, format) when tag in [100, 115, 118, 119] do
    <<104, 3, first::binary>> = data
    match?({:ok, _, [^format]}, term(first, []))
  end

  defp tagged?(_data, _format), do: false

  defp known?(name) do
    _ = :erlang.binary_to_existing_atom(name, :utf8)
    true
  rescue
    ArgumentError -> false
  end

  # One term from the front of `data`: `{:ok, rest, names}` with the atom
  # names it holds added to `names`, or `:error`. Function terms and atom
  # cache references never appear in a saved journal and read as `:error`.
  defp term(<<97, _, rest::binary>>, names), do: {:ok, rest, names}
  defp term(<<98, _::32, rest::binary>>, names), do: {:ok, rest, names}
  defp term(<<70, _::64, rest::binary>>, names), do: {:ok, rest, names}
  defp term(<<99, _::binary-size(31), rest::binary>>, names), do: {:ok, rest, names}
  defp term(<<110, n, _sign, _::binary-size(n), rest::binary>>, names), do: {:ok, rest, names}

  defp term(<<111, n::32, _sign, _::binary-size(n), rest::binary>>, names),
    do: {:ok, rest, names}

  defp term(<<106, rest::binary>>, names), do: {:ok, rest, names}
  defp term(<<107, n::16, _::binary-size(n), rest::binary>>, names), do: {:ok, rest, names}
  defp term(<<109, n::32, _::binary-size(n), rest::binary>>, names), do: {:ok, rest, names}

  defp term(<<77, n::32, _bits, _::binary-size(n), rest::binary>>, names),
    do: {:ok, rest, names}

  defp term(<<104, n, rest::binary>>, names), do: terms(rest, n, names)
  defp term(<<105, n::32, rest::binary>>, names), do: terms(rest, n, names)
  defp term(<<116, n::32, rest::binary>>, names), do: terms(rest, 2 * n, names)
  defp term(<<108, n::32, rest::binary>>, names), do: terms(rest, n + 1, names)
  defp term(<<113, rest::binary>>, names), do: terms(rest, 3, names)

  defp term(<<118, n::16, name::binary-size(n), rest::binary>>, names),
    do: utf8(name, rest, names)

  defp term(<<119, n, name::binary-size(n), rest::binary>>, names), do: utf8(name, rest, names)

  defp term(<<100, n::16, name::binary-size(n), rest::binary>>, names),
    do: latin1(name, rest, names)

  defp term(<<115, n, name::binary-size(n), rest::binary>>, names), do: latin1(name, rest, names)

  defp term(<<88, rest::binary>>, names), do: on_node(rest, 12, names)
  defp term(<<103, rest::binary>>, names), do: on_node(rest, 9, names)
  defp term(<<89, rest::binary>>, names), do: on_node(rest, 8, names)
  defp term(<<120, rest::binary>>, names), do: on_node(rest, 12, names)
  defp term(<<90, n::16, rest::binary>>, names), do: on_node(rest, 4 + 4 * n, names)
  defp term(_data, _names), do: :error

  defp terms(rest, 0, names), do: {:ok, rest, names}

  defp terms(data, n, names) do
    with {:ok, rest, names} <- term(data, names), do: terms(rest, n - 1, names)
  end

  # A pid, port or reference: the node's atom, then `size` bytes.
  defp on_node(data, size, names) do
    case term(data, names) do
      {:ok, <<_::binary-size(^size), rest::binary>>, names} -> {:ok, rest, names}
      _ -> :error
    end
  end

  defp utf8(name, rest, names) do
    if String.valid?(name), do: {:ok, rest, [name | names]}, else: :error
  end

  defp latin1(name, rest, names),
    do: {:ok, rest, [:unicode.characters_to_binary(name, :latin1) | names]}
end
