defmodule PropertyDamage.Corpus.Loader do
  @moduledoc """
  Finds and loads the entries of a corpus directory.

  The shared system and model modules live in `<dir>/support/*.exs`. They load
  first, in name order. Each `<dir>/*.exs` file next to `support/` is one
  entry: it evaluates to a `PropertyDamage.Corpus.Entry`. Entries load in name
  order. An entry with `skip` set needs only a name; any other entry must set
  `engine`, `system`, `model` and `adapter`. A file whose name starts with `baseline_` is a saved table (see
  `PropertyDamage.Corpus.Baseline`), not an entry, and is skipped.
  """

  alias PropertyDamage.Corpus.Entry

  @doc """
  Loads the entries of `dir`, optionally only those whose name is in `only`.

  Returns `{:ok, entries}` or `{:error, message}`.
  """
  @spec load(Path.t(), [String.t()]) :: {:ok, [Entry.t()]} | {:error, String.t()}
  def load(dir, only \\ []) do
    if File.dir?(dir) do
      dir
      |> Path.join("support/*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.each(&require_file/1)

      dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reject(&saved_table?/1)
      |> read_entries(only)
    else
      {:error, "Corpus directory #{dir} does not exist"}
    end
  end

  defp saved_table?(path), do: path |> Path.basename() |> String.starts_with?("baseline_")

  defp require_file(path), do: Code.require_file(path)

  defp read_entries(paths, only) do
    entries = Enum.map(paths, fn path -> {path, path |> Code.eval_file() |> elem(0)} end)

    case Enum.find(entries, fn {_path, value} -> not match?(%Entry{}, value) end) do
      {path, _value} ->
        {:error, "#{path} does not evaluate to a PropertyDamage.Corpus.Entry"}

      nil ->
        with :ok <- check_fields(entries), do: entries |> Enum.map(&elem(&1, 1)) |> select(only)
    end
  end

  @runnable_fields [:engine, :system, :model, :adapter]

  defp check_fields(entries) do
    Enum.find_value(entries, :ok, fn
      {_path, %Entry{skip: reason}} when is_binary(reason) ->
        nil

      {path, entry} ->
        case Enum.filter(@runnable_fields, &is_nil(Map.fetch!(entry, &1))) do
          [] -> nil
          missing -> {:error, "#{path} does not set #{Enum.join(missing, ", ")}"}
        end
    end)
  end

  defp select(entries, []), do: {:ok, entries}

  defp select(entries, only) do
    unknown = only -- Enum.map(entries, & &1.name)

    case unknown do
      [] -> {:ok, Enum.filter(entries, &(&1.name in only))}
      _ -> {:error, "No such entry: #{Enum.join(unknown, ", ")}"}
    end
  end
end
