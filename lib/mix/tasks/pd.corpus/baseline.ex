defmodule PropertyDamage.Corpus.Baseline do
  @moduledoc """
  Saves a measured table to a file and reads it back.

  The file is an Elixir term file. It holds:

    * `:seeds` - every seed measured.
    * `:commit` - `%{sha: String.t() | nil, dirty?: boolean()}`, the commit of
      the working tree at save time and whether it had uncommitted changes.
    * `:engine` - the engine names the entries ran on.
    * `:plan_cap` - the most plans generated per run.
    * `:results` - one `%{entry: name, rows: rows}` per entry, with the raw
      per-seed numbers (see `PropertyDamage.Corpus.Measure`), so a later
      comparison is exact.
  """

  alias PropertyDamage.Corpus.Table

  @type t :: %{
          seeds: [integer()],
          commit: %{sha: String.t() | nil, dirty?: boolean()},
          engine: [String.t()],
          plan_cap: pos_integer(),
          results: [Table.result()]
        }

  @doc "Builds the saved form of `results`, stamped with the current commit."
  @spec build([Table.result()], [String.t()], pos_integer(), [integer()]) :: t()
  def build(results, engines, plan_cap, seeds) do
    %{
      seeds: seeds,
      commit: commit(),
      engine: engines,
      plan_cap: plan_cap,
      results: results
    }
  end

  @doc """
  Writes `baseline` to `path`. Map keys are written in sorted order, so equal
  tables give equal bytes whatever order the atoms were created in.
  """
  @spec save(Path.t(), t()) :: :ok | {:error, File.posix()}
  def save(path, baseline) do
    File.write(
      path,
      inspect(baseline, pretty: true, limit: :infinity, custom_options: [sort_maps: true]) <> "\n"
    )
  end

  @doc "Reads a saved table. Only literal terms are accepted."
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(text),
         true <- Macro.quoted_literal?(quoted) do
      {value, _binding} = Code.eval_quoted(quoted)
      validate(value, path)
    else
      _ -> {:error, "Cannot read a saved table from #{path}"}
    end
  end

  defp validate(%{seeds: _, commit: _, engine: _, plan_cap: _, results: _} = baseline, _path),
    do: {:ok, baseline}

  defp validate(_other, path), do: {:error, "#{path} is not a saved corpus table"}

  # The commit and dirty flag come from git, read at run time. Outside a git
  # checkout the commit is unknown.
  defp commit do
    case git(["rev-parse", "HEAD"]) do
      {:ok, sha} -> %{sha: sha, dirty?: git(["status", "--porcelain"]) != {:ok, ""}}
      :error -> %{sha: nil, dirty?: false}
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end
end
