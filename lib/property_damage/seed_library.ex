defmodule PropertyDamage.SeedLibrary do
  @moduledoc """
  An **ephemeral, self-pruning working set of recently-failing seeds** that
  `PropertyDamage.run/1` replays before random exploration (DR-023).

  Its sole job is to address the probabilistic nature of property-based testing:
  a path that already produced a failure is replayed deterministically at the
  start of a run, so while you fix the bug you do not have to wait for random
  generation to rediscover it.

  This is **not** a durable regression corpus. A seed reproduces its command
  sequence only while the model's generators are byte-stable: changing a
  generator, weight, `when:` predicate, or the command set makes a stored seed
  replay a *different* sequence. A seed is therefore a fragile, version-local
  pointer, not a durable test of a behavior.

  - **Durable regressions belong to the Export subsystem.** Exporting a failure
    to an ExUnit test (`PropertyDamage.Export`) freezes the concrete shrunk
    sequence, which survives generator changes. Use that for anything you want
    to keep.
  - **The library self-cleans.** Each entry tracks a `consecutive_passes`
    streak; an entry is pruned once it reaches the configured threshold
    (default 3). Genuinely-fixed seeds pass repeatedly and age out; flaky seeds
    keep failing intermittently, reset their streak, and self-retain; seeds that
    no longer reproduce anything (generator drift) also simply age out.

  ## Usage

  The library is wired entirely through `PropertyDamage.run/1`; you rarely touch
  this module directly.

      # Enable the working set (default file) — failing seeds are replayed first
      # on the next run, and any new failure's seed is appended.
      PropertyDamage.run(model: M, adapter: A, seed_library: true)

      # Or an explicit file
      PropertyDamage.run(model: M, adapter: A, seed_library: "seeds.json")

  See DR-023 for the full design.

  ## Seed Entry Structure

  Each entry contains:
  - `seed` - The random seed value
  - `model` - Model module name (descriptive)
  - `failure_type` - What kind of failure it last produced (descriptive)
  - `check_name` - Which check last failed, if applicable (descriptive)
  - `tags` - User-provided categorization tags
  - `description` - Human-readable description
  - `discovered_at` - When the seed was added
  - `last_run` - When the seed was last replayed
  - `consecutive_passes` - Replays in a row without a failure; reset to 0 on any
    failure, and the entry is pruned once it reaches the prune threshold
  - `dependency_versions` - Dependency versions captured at discovery (descriptive)

  `failure_type`, `check_name`, and `dependency_versions` are inert descriptive
  metadata: they appear in the console banner and in `stats/1`/`format/1` but
  participate in no verdict logic.
  """

  @library_version 2
  @default_file "property_damage_seeds.json"
  @default_prune_threshold 3

  @type seed_entry :: %{
          seed: integer(),
          model: String.t(),
          failure_type: atom(),
          check_name: atom() | nil,
          tags: [atom()],
          description: String.t() | nil,
          discovered_at: String.t(),
          last_run: String.t() | nil,
          consecutive_passes: non_neg_integer(),
          dependency_versions: %{atom() => String.t()}
        }

  @type t :: %{
          version: integer(),
          entries: [seed_entry()]
        }

  @doc """
  The default prune threshold (`K`): an entry is removed after this many
  consecutive passing replays.
  """
  @spec default_prune_threshold() :: pos_integer()
  def default_prune_threshold, do: @default_prune_threshold

  @doc """
  The default seed library filename.
  """
  @spec default_file() :: Path.t()
  def default_file, do: @default_file

  @doc """
  Create a new empty seed library.
  """
  @spec new() :: t()
  def new do
    %{
      version: @library_version,
      entries: []
    }
  end

  @doc """
  Add a seed from a failure report to the library.

  Entries are prepended, so the library is ordered most-recently-discovered
  first (the order in which `run/1` replays them).

  ## Options

  - `:tags` - List of categorization tags (e.g., `[:currency, :race_condition]`)
  - `:description` - Human-readable description of what this seed tests

  Duplicate seeds are rejected with `{:error, {:duplicate_seed, seed}}`.
  """
  @spec add(t(), PropertyDamage.FailureReport.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def add(library, %PropertyDamage.FailureReport{} = failure, opts \\ []) do
    entry = %{
      seed: failure.seed,
      model: inspect(failure.model),
      failure_type: PropertyDamage.FailureReport.failure_type(failure),
      check_name: PropertyDamage.FailureReport.check_name(failure),
      tags: Keyword.get(opts, :tags, []),
      description: Keyword.get(opts, :description),
      discovered_at: now_iso8601(),
      last_run: nil,
      consecutive_passes: 0,
      dependency_versions: PropertyDamage.Persistence.capture_dependency_versions(failure)
    }

    insert_unique(library, entry)
  end

  @doc """
  Add a seed directly (without a failure report).

  Useful for manual entry. Duplicate seeds are rejected.

  ## Example

      {:ok, library} = SeedLibrary.add_seed(library, 512902757,
        model: "MyApp.Model",
        tags: [:currency_mismatch],
        description: "Captures with mismatched currencies"
      )
  """
  @spec add_seed(t(), integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def add_seed(library, seed, opts \\ []) do
    entry = %{
      seed: seed,
      model: Keyword.get(opts, :model, "unknown"),
      failure_type: Keyword.get(opts, :failure_type, :unknown),
      check_name: Keyword.get(opts, :check_name),
      tags: Keyword.get(opts, :tags, []),
      description: Keyword.get(opts, :description),
      discovered_at: now_iso8601(),
      last_run: nil,
      consecutive_passes: 0,
      dependency_versions: Keyword.get(opts, :dependency_versions, %{})
    }

    insert_unique(library, entry)
  end

  defp insert_unique(library, entry) do
    if Enum.any?(library.entries, &(&1.seed == entry.seed)) do
      {:error, {:duplicate_seed, entry.seed}}
    else
      {:ok, %{library | entries: [entry | library.entries]}}
    end
  end

  @doc """
  Remove a seed from the library.
  """
  @spec remove(t(), integer()) :: {:ok, t()} | {:error, :not_found}
  def remove(library, seed) do
    case Enum.split_with(library.entries, &(&1.seed == seed)) do
      {[], _} -> {:error, :not_found}
      {_, remaining} -> {:ok, %{library | entries: remaining}}
    end
  end

  @doc """
  Record the result of replaying a seed, updating its `consecutive_passes`
  streak (DR-023). The verdict is binary:

  - a **passing** replay increments the streak;
  - a **failing** replay resets the streak to 0 and refreshes the entry's
    descriptive `failure_type`/`check_name` from the new report (via the
    `:failure_type`/`:check_name` options) so the description never goes stale.

  Pruning of streaks that have reached the threshold is a separate step
  (`prune/2`), applied after a full replay pass.

  ## Options

  - `:failed` - Whether the replay failed (default `false`)
  - `:failure_type` - Refreshed failure type (used only when `failed: true`)
  - `:check_name` - Refreshed check name (used only when `failed: true`)
  """
  @spec record_run(t(), integer(), keyword()) :: t()
  def record_run(library, seed, opts \\ []) do
    failed = Keyword.get(opts, :failed, false)
    now = now_iso8601()

    entries =
      Enum.map(library.entries, fn entry ->
        if entry.seed == seed do
          record_entry(entry, failed, opts, now)
        else
          entry
        end
      end)

    %{library | entries: entries}
  end

  defp record_entry(entry, false, _opts, now) do
    %{entry | consecutive_passes: entry.consecutive_passes + 1, last_run: now}
  end

  defp record_entry(entry, true, opts, now) do
    %{
      entry
      | consecutive_passes: 0,
        failure_type: Keyword.get(opts, :failure_type, entry.failure_type),
        check_name: Keyword.get(opts, :check_name, entry.check_name),
        last_run: now
    }
  end

  @doc """
  Remove entries whose `consecutive_passes` streak has reached `k` (DR-023).

  Returns `{pruned_library, removed_count}`.
  """
  @spec prune(t(), pos_integer()) :: {t(), non_neg_integer()}
  def prune(library, k \\ @default_prune_threshold) do
    {kept, removed} = Enum.split_with(library.entries, &(&1.consecutive_passes < k))
    {%{library | entries: kept}, length(removed)}
  end

  @doc """
  Load a seed library from a JSON file.

  Tolerates libraries written by older versions: missing fields (including the
  pre-DR-023 `status`/`run_count`/`fail_count` tri-state) are dropped and a
  fresh `consecutive_passes` streak of 0 is assumed.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ @default_file) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content, keys: :atoms) do
      entries = Enum.map(data.entries, &load_entry/1)
      {:ok, %{version: @library_version, entries: entries}}
    else
      # A missing default file just means no library has been created yet, so
      # start fresh. A missing *explicit* path is almost always a typo, so
      # surface it rather than masking it with an empty library.
      {:error, :enoent} when path == @default_file -> {:ok, new()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_entry(entry) do
    %{
      seed: entry.seed,
      model: entry[:model] || "unknown",
      failure_type: to_atom_safe(entry[:failure_type]) || :unknown,
      check_name: to_atom_safe(entry[:check_name]),
      tags: Enum.map(entry[:tags] || [], &to_atom_safe/1),
      description: entry[:description],
      discovered_at: entry[:discovered_at],
      last_run: entry[:last_run],
      consecutive_passes: entry[:consecutive_passes] || 0,
      dependency_versions: atomize_dep_versions(entry[:dependency_versions])
    }
  end

  @doc """
  Save a seed library to a JSON file.

  The write is **atomic**: the JSON is written to a temporary file in the same
  directory and then renamed over the destination, so a concurrent reader never
  observes a partially-written file.
  """
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(library, path \\ @default_file) do
    json = Jason.encode!(library, pretty: true)
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  @doc """
  Get statistics about the library.
  """
  @spec stats(t()) :: map()
  def stats(library) do
    entries = library.entries

    %{
      total: length(entries),
      by_failure_type: Enum.frequencies_by(entries, & &1.failure_type),
      by_model: Enum.frequencies_by(entries, & &1.model),
      tags: entries |> Enum.flat_map(& &1.tags) |> Enum.frequencies()
    }
  end

  @doc """
  Format library for display.
  """
  @spec format(t()) :: String.t()
  def format(library) do
    stats = stats(library)

    header = "Seed Library: #{stats.total} seed(s) (ephemeral replay working set)\n"

    entries_str =
      library.entries
      |> Enum.take(10)
      |> Enum.map_join("\n", fn e ->
        tags_str = if e.tags != [], do: " [#{Enum.join(e.tags, ", ")}]", else: ""
        "  #{e.seed} - #{e.failure_type}#{tags_str} (passes: #{e.consecutive_passes})"
      end)

    header <> "\nRecent entries:\n" <> entries_str
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp now_iso8601, do: DateTime.to_iso8601(DateTime.utc_now())

  defp to_atom_safe(nil), do: nil
  defp to_atom_safe(atom) when is_atom(atom), do: atom
  defp to_atom_safe(string) when is_binary(string), do: String.to_atom(string)

  defp atomize_dep_versions(nil), do: %{}

  defp atomize_dep_versions(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_atom_safe(k), v} end)
  end
end
