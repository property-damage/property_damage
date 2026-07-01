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

  ## Sensitive data

  A `.pd` file losslessly preserves the failing run: the command structs, the
  full event log, and projection state at the point of failure. If those carry
  personal or otherwise sensitive data (account numbers, emails, tokens), so
  does the saved file. Treat `.pd` files as you would the data they capture:

  - Do not commit them to a public repository or attach them to a public issue.
  - Scrub or synthesize sensitive fields in your commands/events before saving
    if the file will be shared, or keep saved failures in a controlled location.

  PropertyDamage does not redact automatically; what the run touched is what the
  file holds.
  """

  alias PropertyDamage.{FailureReport, Sequence}

  @version 3
  @extension ".pd"

  # Fields removed from FailureReport after a given format version. A file
  # written by an older version carries them; binary_to_term faithfully
  # reconstructs the stored shape, so a loaded pre-v3 report has these as
  # *extra* keys. Their presence is expected and benign (the data they held is
  # recomputed on demand via FailureReport.failure_step/1 from the untouched
  # event_log + shrunk_sequence), so they are not reported as struct drift.
  @removed_fields [:command_at_failure, :events_at_failure]

  # Upper bound on the term size we are willing to reconstruct from a file.
  # Compressed external term format declares its uncompressed size in the
  # header; a hostile file can claim a multi-gigabyte expansion from a few
  # bytes (a decompression bomb). Legitimate failure reports are tiny, so a
  # generous 128 MiB cap rejects abuse without affecting real use.
  @max_uncompressed_size 128 * 1024 * 1024

  @type warning ::
          {:property_damage_version_mismatch, String.t(), String.t()}
          | {:dependency_version_mismatch, atom(), String.t(), String.t()}
          | {:dependency_missing, atom(), String.t()}
          | {:struct_shape_drift, [atom()], [atom()]}

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

    if File.exists?(path) and not overwrite do
      {:error, {:file_exists, path}}
    else
      # Create the target directory if needed. Previously save returned
      # {:directory_not_found, _}, and callers in the on_failure / regression
      # path discarded that error, so failures were silently not persisted
      # whenever the directory had not been pre-created.
      case File.mkdir_p(directory) do
        :ok -> do_save(report, path)
        {:error, reason} -> {:error, {:mkdir_failed, directory, reason}}
      end
    end
  end

  @doc """
  Load a failure report from disk.

  ## Returns

  - `{:ok, report}` - Successfully loaded FailureReport with no version warnings
  - `{:ok, report, warnings}` - Loaded with version compatibility warnings
  - `{:error, reason}` - File not found, corrupted, incompatible version, etc.

  Version warnings indicate that the saved test may not reproduce correctly
  due to changes in PropertyDamage or dependency versions. Warnings include:

  - `{:property_damage_version_mismatch, saved_version, current_version}`
  - `{:dependency_version_mismatch, app, saved_version, current_version}`
  - `{:dependency_missing, app, saved_version}`

  ## Examples

      {:ok, failure} = Persistence.load("failures/currency-bug.pd")
      PropertyDamage.replay(failure)

      # With version warnings
      {:ok, failure, warnings} = Persistence.load("failures/old-test.pd")
      IO.warn("Version mismatch: \#{inspect(warnings)}")
  """
  @spec load(Path.t()) ::
          {:ok, FailureReport.t()} | {:ok, FailureReport.t(), [warning()]} | {:error, term()}
  def load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, report, warnings} <- decode(binary) do
      if warnings == [] do
        {:ok, report}
      else
        {:ok, report, warnings}
      end
    else
      {:error, :enoent} -> {:error, {:file_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load a failure report, raising on version warnings.

  Use this when you want strict version compatibility. Raises `ArgumentError`
  if there are any version mismatches between the saved file and current
  environment.

  ## Examples

      report = Persistence.load!("failures/currency-bug.pd")
  """
  @spec load!(Path.t()) :: FailureReport.t()
  def load!(path) do
    case load(path) do
      {:ok, report} ->
        report

      {:ok, _report, warnings} ->
        raise ArgumentError, """
        Version compatibility warnings loading #{path}:
        #{format_warnings(warnings)}

        Use Persistence.load/1 to load with warnings, or regenerate the test.
        """

      {:error, reason} ->
        raise ArgumentError, "Failed to load #{path}: #{inspect(reason)}"
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
      {:ok, _, _warnings} -> true
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
      shrunk_command_count: length(Sequence.to_list(report.shrunk_sequence)),
      original_command_count: length(Sequence.to_list(report.original_sequence)),
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
      format_version: @version,
      report: report,
      metadata: %{
        property_damage_version: pd_version(),
        elixir_version: System.version(),
        dependency_versions: capture_dependency_versions(report),
        saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
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

  # V1 format - no metadata, no warnings
  defp decode(<<"PD", 1::8, stored_checksum::32, term_binary::binary>>) do
    actual_checksum = :erlang.crc32(term_binary)

    cond do
      actual_checksum != stored_checksum ->
        {:error, :checksum_mismatch}

      not within_size_limit?(term_binary) ->
        {:error, :term_too_large}

      true ->
        try do
          %{report: report} = :erlang.binary_to_term(term_binary, [:safe])
          {:ok, report, check_struct_drift(report)}
        rescue
          # The checksum already matched, so the bytes are intact: a [:safe]
          # decode failure here means the term references atoms/modules that do
          # not exist in this VM (e.g. the SUT's command/event structs aren't
          # loaded), not byte corruption. Report it accurately.
          ArgumentError -> {:error, :unsafe_terms}
        end
    end
  end

  # V2/V3 format - metadata payload. V3 is identical in shape; the version bump
  # only records that FailureReport dropped command_at_failure/events_at_failure
  # (see @removed_fields), which is why both versions decode the same way.
  defp decode(<<"PD", 2::8, stored_checksum::32, term_binary::binary>>) do
    decode_metadata_payload(stored_checksum, term_binary)
  end

  defp decode(<<"PD", 3::8, stored_checksum::32, term_binary::binary>>) do
    decode_metadata_payload(stored_checksum, term_binary)
  end

  defp decode(<<"PD", version::8, _checksum::32, _term_binary::binary>>)
       when version > @version do
    {:error, {:incompatible_version, version, @version}}
  end

  defp decode(_), do: {:error, :invalid_format}

  defp decode_metadata_payload(stored_checksum, term_binary) do
    actual_checksum = :erlang.crc32(term_binary)

    cond do
      actual_checksum != stored_checksum ->
        {:error, :checksum_mismatch}

      not within_size_limit?(term_binary) ->
        {:error, :term_too_large}

      true ->
        try do
          payload = :erlang.binary_to_term(term_binary, [:safe])

          warnings =
            check_version_compatibility(payload[:metadata] || %{}) ++
              check_struct_drift(payload.report)

          {:ok, payload.report, warnings}
        rescue
          # See the v1 clause: post-checksum, this is unknown/unloadable terms
          # rather than corruption.
          ArgumentError -> {:error, :unsafe_terms}
        end
    end
  end

  # The external term format declares its uncompressed size in the header for
  # compressed terms (`<<131, 80, size::32, ...>>`); bound that BEFORE decoding
  # so a decompression bomb cannot make the VM preallocate gigabytes. For an
  # uncompressed term the byte size is already a faithful upper bound.
  defp within_size_limit?(<<131, 80, uncompressed_size::unsigned-32, _rest::binary>>) do
    uncompressed_size <= @max_uncompressed_size
  end

  defp within_size_limit?(term_binary) do
    byte_size(term_binary) <= @max_uncompressed_size
  end

  defp pd_version do
    case Application.spec(:property_damage, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Capture dependency versions from a failure report.

  Extracts struct modules from commands and events, then looks up their
  application versions. This enables version tracking for saved test files.
  """
  @spec capture_dependency_versions(FailureReport.t()) :: %{atom() => String.t()}
  def capture_dependency_versions(%FailureReport{} = report) do
    modules = extract_struct_modules(report)

    modules
    |> Enum.map(&module_to_app_version/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp extract_struct_modules(%FailureReport{shrunk_sequence: seq, event_log: events}) do
    command_modules =
      seq
      |> Sequence.to_list()
      |> Enum.map(& &1.__struct__)

    event_modules =
      events
      |> Enum.map(fn entry -> entry.event && entry.event.__struct__ end)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(command_modules ++ event_modules)
  end

  defp module_to_app_version(module) do
    case :application.get_application(module) do
      {:ok, app} ->
        case Application.spec(app, :vsn) do
          nil -> nil
          vsn -> {app, to_string(vsn)}
        end

      :undefined ->
        nil
    end
  end

  defp check_version_compatibility(metadata) do
    warnings = []

    # Check PropertyDamage version
    saved = metadata[:property_damage_version]
    current = pd_version()

    warnings =
      if saved && saved != current && saved != "unknown" do
        [{:property_damage_version_mismatch, saved, current} | warnings]
      else
        warnings
      end

    # Check dependency versions - warn on ANY version change
    # since struct changes can happen in any release (major, minor, or patch)
    saved_deps = metadata[:dependency_versions] || %{}

    dep_warnings =
      Enum.flat_map(saved_deps, fn {app, saved_vsn} ->
        case Application.spec(app, :vsn) do
          nil ->
            [{:dependency_missing, app, saved_vsn}]

          current_vsn ->
            current = to_string(current_vsn)

            if current != saved_vsn do
              [{:dependency_version_mismatch, app, saved_vsn, current}]
            else
              []
            end
        end
      end)

    warnings ++ dep_warnings
  end

  # Compare a loaded report's field set against the current FailureReport
  # definition. binary_to_term reconstructs whatever shape was stored, so a
  # file written by a PD version with a different struct can deserialize into a
  # struct missing (or carrying stale) fields without any error. Surface that as
  # a warning rather than letting it pass silently.
  defp check_struct_drift(report) when is_struct(report, FailureReport) do
    current = MapSet.new(Map.keys(%FailureReport{}))
    loaded = MapSet.new(Map.keys(report))

    missing = current |> MapSet.difference(loaded) |> Enum.sort()

    # Keys intentionally removed in a later format version are expected on an
    # older file and are not drift; only genuinely-unknown keys are surfaced.
    unexpected =
      loaded
      |> MapSet.difference(current)
      |> MapSet.difference(MapSet.new(@removed_fields))
      |> Enum.sort()

    if missing == [] and unexpected == [] do
      []
    else
      [{:struct_shape_drift, missing, unexpected}]
    end
  end

  defp check_struct_drift(_), do: []

  defp format_warnings(warnings) do
    Enum.map_join(warnings, "\n", fn
      {:property_damage_version_mismatch, saved, current} ->
        "  - PropertyDamage: saved=#{saved}, current=#{current}"

      {:dependency_version_mismatch, app, saved, current} ->
        "  - #{app}: saved=#{saved}, current=#{current}"

      {:dependency_missing, app, saved} ->
        "  - #{app}: was #{saved}, now missing"

      {:struct_shape_drift, missing, unexpected} ->
        "  - FailureReport struct shape drifted (missing: #{inspect(missing)}, " <>
          "unexpected: #{inspect(unexpected)})"
    end)
  end

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
              shrunk_size: length(Sequence.to_list(report.shrunk_sequence))
            }

          {:ok, report, _warnings} ->
            %{
              seed: report.seed,
              failure_type: report.failure_type,
              check_name: report.check_name,
              timestamp: report.timestamp,
              shrunk_size: length(Sequence.to_list(report.shrunk_sequence))
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
           # to_existing_atom (not to_atom): a directory of crafted filenames must
           # not be able to exhaust the atom table. An unknown check-name raises
           # ArgumentError below and drops to the accurate full-load fallback.
           check_name: String.to_existing_atom(check),
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
