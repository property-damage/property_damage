defmodule PropertyDamage.Persistence do
  @moduledoc """
  Save and load failure reports for later analysis and regression testing.

  Failures are saved in Erlang term format (.pd files) which preserves
  all struct information losslessly. This enables:

  - Debugging failures later without re-running tests
  - Building regression test suites from discovered bugs
  - Sharing failures across team members
  - Tracking which bugs have been fixed

  ## Usage

      # Save a failure
      {:error, failure} = PropertyDamage.run(model: M, adapter: A)
      {:ok, path} = PropertyDamage.save_failure(failure, "failures/")

      # Load and replay later
      {:ok, failure} = PropertyDamage.load_failure(path)
      PropertyDamage.replay(failure)

      # List all saved failures
      failures = PropertyDamage.list_failures("failures/")

  ## File Format

  Files use the `.pd` extension and contain:
  - Version header for forward compatibility
  - Erlang term-encoded FailureReport struct
  - Checksum for integrity verification

  ## Naming Convention

  Auto-generated filenames follow the pattern:
  `{timestamp}-{failure_type}-{check_name}-seed{seed}.pd`

  Example: `2025-12-26T14-30-00-check_failed-NonNegativeBalance-seed512902757.pd`
  """

  alias PropertyDamage.FailureReport

  @version 1
  @extension ".pd"

  @type save_opts :: [
          filename: String.t(),
          overwrite: boolean()
        ]

  @doc """
  Save a failure report to disk.

  ## Options

  - `:filename` - Custom filename (default: auto-generated from failure metadata)
  - `:overwrite` - Whether to overwrite existing files (default: false)

  ## Returns

  - `{:ok, path}` - Full path to saved file
  - `{:error, reason}` - File already exists, directory doesn't exist, etc.

  ## Examples

      # Save with auto-generated name
      {:ok, path} = Persistence.save(failure, "failures/")
      # => {:ok, "failures/2025-12-26T14-30-00-check_failed-NonNegativeBalance-seed512902757.pd"}

      # Save with custom name
      {:ok, path} = Persistence.save(failure, "failures/", filename: "currency-bug.pd")
  """
  @spec save(FailureReport.t(), Path.t(), save_opts()) :: {:ok, Path.t()} | {:error, term()}
  def save(%FailureReport{} = report, directory, opts \\ []) do
    filename = Keyword.get(opts, :filename) || generate_filename(report)
    overwrite = Keyword.get(opts, :overwrite, false)
    path = Path.join(directory, filename)

    cond do
      not File.dir?(directory) ->
        {:error, {:directory_not_found, directory}}

      File.exists?(path) and not overwrite ->
        {:error, {:file_exists, path}}

      true ->
        do_save(report, path)
    end
  end

  @doc """
  Load a failure report from disk.

  ## Returns

  - `{:ok, report}` - Successfully loaded FailureReport
  - `{:error, reason}` - File not found, corrupted, incompatible version, etc.

  ## Examples

      {:ok, failure} = Persistence.load("failures/currency-bug.pd")
      PropertyDamage.replay(failure)
  """
  @spec load(Path.t()) :: {:ok, FailureReport.t()} | {:error, term()}
  def load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, report} <- decode(binary) do
      {:ok, report}
    else
      {:error, :enoent} -> {:error, {:file_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List all saved failures in a directory.

  Returns a list of maps with failure metadata (without loading full reports).

  ## Options

  - `:sort` - Sort order: `:newest`, `:oldest`, `:seed` (default: `:newest`)
  - `:filter` - Filter function `(metadata -> boolean)`

  ## Examples

      # List all failures
      failures = Persistence.list("failures/")
      # => [%{path: "...", seed: 123, failure_type: :check_failed, ...}, ...]

      # List only check failures
      failures = Persistence.list("failures/", filter: &(&1.failure_type == :check_failed))
  """
  @spec list(Path.t(), keyword()) :: [map()]
  def list(directory, opts \\ []) do
    sort = Keyword.get(opts, :sort, :newest)
    filter_fn = Keyword.get(opts, :filter, fn _ -> true end)

    case File.ls(directory) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, @extension))
        |> Enum.map(fn filename ->
          path = Path.join(directory, filename)
          metadata = extract_metadata(path, filename)
          Map.put(metadata, :path, path)
        end)
        |> Enum.filter(filter_fn)
        |> sort_failures(sort)

      {:error, _} ->
        []
    end
  end

  @doc """
  Delete a saved failure.

  ## Returns

  - `:ok` - File deleted
  - `{:error, reason}` - File not found, permission denied, etc.
  """
  @spec delete(Path.t()) :: :ok | {:error, term()}
  def delete(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, {:file_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a failure file is valid and loadable.

  Performs integrity check without fully loading the report.
  """
  @spec valid?(Path.t()) :: boolean()
  def valid?(path) do
    case load(path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Export a failure to JSON format for external tools.

  Note: JSON export is lossy - some Elixir-specific data may be simplified.
  Use `save/3` for lossless storage.
  """
  @spec export_json(FailureReport.t()) :: String.t()
  def export_json(%FailureReport{} = report) do
    %{
      version: @version,
      seed: report.seed,
      run_number: report.run_number,
      failed_at_index: report.failed_at_index,
      failure_type: report.failure_type,
      check_name: report.check_name,
      failure_message: report.failure_message,
      shrink_iterations: report.shrink_iterations,
      shrink_time_ms: report.shrink_time_ms,
      timestamp: DateTime.to_iso8601(report.timestamp),
      model: report.model && inspect(report.model),
      adapter: report.adapter && inspect(report.adapter),
      shrunk_command_count: length(PropertyDamage.Sequence.to_list(report.shrunk_sequence)),
      original_command_count: length(PropertyDamage.Sequence.to_list(report.original_sequence)),
      reproduction_command: FailureReport.reproduction_command(report)
    }
    |> Jason.encode!(pretty: true)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp do_save(report, path) do
    binary = encode(report)

    case File.write(path, binary) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp encode(%FailureReport{} = report) do
    payload = %{
      version: @version,
      report: report
    }

    term_binary = :erlang.term_to_binary(payload, [:compressed])
    checksum = :erlang.crc32(term_binary)

    <<
      "PD",
      @version::8,
      checksum::32,
      term_binary::binary
    >>
  end

  defp decode(<<"PD", version::8, stored_checksum::32, term_binary::binary>>) do
    if version > @version do
      {:error, {:incompatible_version, version, @version}}
    else
      actual_checksum = :erlang.crc32(term_binary)

      if actual_checksum != stored_checksum do
        {:error, :checksum_mismatch}
      else
        try do
          %{report: report} = :erlang.binary_to_term(term_binary, [:safe])
          {:ok, report}
        rescue
          ArgumentError -> {:error, :corrupted_data}
        end
      end
    end
  end

  defp decode(_), do: {:error, :invalid_format}

  defp generate_filename(%FailureReport{} = report) do
    timestamp =
      report.timestamp
      |> DateTime.to_iso8601(:basic)
      |> String.replace(":", "-")
      |> String.slice(0, 15)

    type = report.failure_type || "unknown"
    check = report.check_name || "none"
    seed = report.seed

    "#{timestamp}-#{type}-#{check}-seed#{seed}#{@extension}"
  end

  defp extract_metadata(path, filename) do
    # Try to extract metadata from filename first (fast)
    case parse_filename(filename) do
      {:ok, metadata} ->
        # Add file stats
        case File.stat(path) do
          {:ok, stat} -> Map.put(metadata, :file_size, stat.size)
          _ -> metadata
        end

      :error ->
        # Fall back to loading the file (slow but accurate)
        case load(path) do
          {:ok, report} ->
            %{
              seed: report.seed,
              failure_type: report.failure_type,
              check_name: report.check_name,
              timestamp: report.timestamp,
              shrunk_size: length(PropertyDamage.Sequence.to_list(report.shrunk_sequence))
            }

          {:error, _} ->
            %{filename: filename, error: :unreadable}
        end
    end
  end

  defp parse_filename(filename) do
    # Pattern: {timestamp}-{type}-{check}-seed{seed}.pd
    case Regex.run(
           ~r/^(\d{8}T\d{6})-(\w+)-(\w+)-seed(\d+)\.pd$/,
           filename
         ) do
      [_, timestamp_str, type, check, seed_str] ->
        {:ok,
         %{
           timestamp: parse_timestamp(timestamp_str),
           failure_type: String.to_existing_atom(type),
           check_name: String.to_atom(check),
           seed: String.to_integer(seed_str)
         }}

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_timestamp(str) do
    # Basic ISO format: 20251226T143000
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/, str) do
      [_, y, m, d, h, min, s] ->
        {:ok, dt, _} =
          DateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:#{min}:#{s}Z")

        dt

      _ ->
        nil
    end
  end

  defp sort_failures(failures, :newest) do
    Enum.sort_by(failures, & &1[:timestamp], {:desc, DateTime})
  end

  defp sort_failures(failures, :oldest) do
    Enum.sort_by(failures, & &1[:timestamp], {:asc, DateTime})
  end

  defp sort_failures(failures, :seed) do
    Enum.sort_by(failures, & &1[:seed])
  end
end
