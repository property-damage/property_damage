defmodule PropertyDamage.SeedLibrary do
  @moduledoc """
  Manage a collection of interesting seeds for regression testing and sharing.

  The Seed Library tracks seeds that have found bugs, allowing you to:

  - Run known-interesting seeds first before random exploration
  - Share discovered seeds across team members
  - Build a regression suite that catches known bug patterns
  - Track which seeds have been fixed vs still failing

  ## Usage

      # Add a seed when you find a bug
      {:error, failure} = PropertyDamage.run(model: M, adapter: A)
      SeedLibrary.add(failure, tags: [:currency, :capture])

      # Run all library seeds first, then continue with random
      PropertyDamage.run(model: M, adapter: A, seed_library: "seeds.json")

      # Export for CI/sharing
      SeedLibrary.export("seeds.json")

  ## Seed Entry Structure

  Each entry contains:
  - `seed` - The random seed value
  - `model` - Model module name (for filtering)
  - `failure_type` - What kind of failure it found
  - `check_name` - Which check failed (if applicable)
  - `tags` - User-provided categorization tags
  - `description` - Human-readable description
  - `discovered_at` - When the seed was added
  - `last_run` - When the seed was last tested
  - `status` - `:failing`, `:fixed`, `:flaky`
  - `run_count` - How many times this seed has been run
  - `fail_count` - How many times it has failed

  ## Integration with PropertyDamage.run

  When a seed library is provided, `PropertyDamage.run` will:

  1. Run all `:failing` seeds from the library first
  2. Update seed status based on results
  3. Continue with random seed exploration
  """

  @library_version 1
  @default_file "property_damage_seeds.json"

  @type seed_entry :: %{
          seed: integer(),
          model: String.t(),
          failure_type: atom(),
          check_name: atom() | nil,
          tags: [atom()],
          description: String.t() | nil,
          discovered_at: String.t(),
          last_run: String.t() | nil,
          status: :failing | :fixed | :flaky | :unknown,
          run_count: non_neg_integer(),
          fail_count: non_neg_integer(),
          dependency_versions: %{atom() => String.t()}
        }

  @type t :: %{
          version: integer(),
          entries: [seed_entry()]
        }

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

  ## Options

  - `:tags` - List of categorization tags (e.g., `[:currency, :race_condition]`)
  - `:description` - Human-readable description of what this seed tests

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)
      {:ok, library} = SeedLibrary.add(library, failure, tags: [:currency])
  """
  @spec add(t(), PropertyDamage.FailureReport.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def add(library, %PropertyDamage.FailureReport{} = failure, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])
    description = Keyword.get(opts, :description)

    entry = %{
      seed: failure.seed,
      model: inspect(failure.model),
      failure_type: failure.failure_type,
      check_name: failure.check_name,
      tags: tags,
      description: description,
      discovered_at: DateTime.to_iso8601(DateTime.utc_now()),
      last_run: nil,
      status: :failing,
      run_count: 0,
      fail_count: 0,
      dependency_versions: PropertyDamage.Persistence.capture_dependency_versions(failure)
    }

    # Check for duplicate seed
    if Enum.any?(library.entries, &(&1.seed == failure.seed)) do
      {:error, {:duplicate_seed, failure.seed}}
    else
      {:ok, %{library | entries: [entry | library.entries]}}
    end
  end

  @doc """
  Add a seed directly (without a failure report).

  Useful for importing seeds from external sources or manual entry.

  ## Example

      {:ok, library} = SeedLibrary.add_seed(library, 512902757,
        model: "ToyBankTest.Model",
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
      discovered_at: DateTime.to_iso8601(DateTime.utc_now()),
      last_run: nil,
      status: Keyword.get(opts, :status, :unknown),
      run_count: 0,
      fail_count: 0,
      dependency_versions: Keyword.get(opts, :dependency_versions, %{})
    }

    if Enum.any?(library.entries, &(&1.seed == seed)) do
      {:error, {:duplicate_seed, seed}}
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
  Update a seed's status after a test run.

  ## Example

      # After running a seed
      library = SeedLibrary.record_run(library, seed, failed: true)
  """
  @spec record_run(t(), integer(), keyword()) :: t()
  def record_run(library, seed, opts \\ []) do
    failed = Keyword.get(opts, :failed, false)

    entries =
      Enum.map(library.entries, fn entry ->
        if entry.seed == seed do
          new_run_count = entry.run_count + 1
          new_fail_count = if failed, do: entry.fail_count + 1, else: entry.fail_count

          # Update status based on recent runs
          new_status =
            cond do
              new_run_count < 3 -> entry.status
              new_fail_count == 0 -> :fixed
              new_fail_count == new_run_count -> :failing
              true -> :flaky
            end

          %{
            entry
            | run_count: new_run_count,
              fail_count: new_fail_count,
              status: new_status,
              last_run: DateTime.to_iso8601(DateTime.utc_now())
          }
        else
          entry
        end
      end)

    %{library | entries: entries}
  end

  @doc """
  Get all seeds matching certain criteria.

  ## Options

  - `:status` - Filter by status (`:failing`, `:fixed`, `:flaky`)
  - `:tags` - Filter by tags (entries must have ALL specified tags)
  - `:model` - Filter by model name (string match)

  ## Example

      # Get all failing seeds
      failing = SeedLibrary.get_seeds(library, status: :failing)

      # Get currency-related seeds
      currency_seeds = SeedLibrary.get_seeds(library, tags: [:currency])
  """
  @spec get_seeds(t(), keyword()) :: [seed_entry()]
  def get_seeds(library, opts \\ []) do
    status = Keyword.get(opts, :status)
    tags = Keyword.get(opts, :tags, [])
    model = Keyword.get(opts, :model)

    library.entries
    |> maybe_filter_status(status)
    |> maybe_filter_tags(tags)
    |> maybe_filter_model(model)
  end

  @doc """
  Get just the seed values (for passing to PropertyDamage.run).

  ## Example

      seeds = SeedLibrary.seed_values(library, status: :failing)
      # => [512902757, 123456789, ...]
  """
  @spec seed_values(t(), keyword()) :: [integer()]
  def seed_values(library, opts \\ []) do
    library
    |> get_seeds(opts)
    |> Enum.map(& &1.seed)
  end

  @doc """
  Load a seed library from a JSON file.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ @default_file) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content, keys: :atoms) do
      # Convert string status to atoms and handle dependency_versions
      entries =
        Enum.map(data.entries, fn entry ->
          base = %{
            entry
            | status: to_status_atom(entry.status),
              failure_type: to_atom_safe(entry.failure_type),
              check_name: to_atom_safe(entry.check_name),
              tags: Enum.map(entry.tags, &to_atom_safe/1)
          }

          # Handle dependency_versions field (may be missing in old libraries)
          Map.put(base, :dependency_versions, atomize_dep_versions(entry[:dependency_versions]))
        end)

      {:ok, %{data | entries: entries}}
    else
      # A missing default file just means no library has been created yet, so
      # start fresh. A missing *explicit* path is almost always a typo, so
      # surface it rather than masking it with an empty library.
      {:error, :enoent} when path == @default_file -> {:ok, new()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Save a seed library to a JSON file.
  """
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(library, path \\ @default_file) do
    json = Jason.encode!(library, pretty: true)
    File.write(path, json)
  end

  @doc """
  Export library to a portable format (for sharing).

  Unlike save/2, this includes only essential fields and uses strings
  for module names to avoid atom table issues across systems.
  """
  @spec export(t(), Path.t()) :: :ok | {:error, term()}
  def export(library, path) do
    portable =
      %{
        version: @library_version,
        exported_at: DateTime.to_iso8601(DateTime.utc_now()),
        entries:
          Enum.map(library.entries, fn e ->
            %{
              seed: e.seed,
              model: e.model,
              failure_type: to_string(e.failure_type),
              check_name: e.check_name && to_string(e.check_name),
              tags: Enum.map(e.tags, &to_string/1),
              description: e.description,
              status: to_string(e.status)
            }
          end)
      }

    json = Jason.encode!(portable, pretty: true)
    File.write(path, json)
  end

  @doc """
  Import seeds from an exported file.

  Merges with existing library, skipping duplicates.
  """
  @spec import(t(), Path.t()) :: {:ok, t(), non_neg_integer()} | {:error, term()}
  def import(library, path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content, keys: :atoms) do
      existing_seeds = MapSet.new(library.entries, & &1.seed)

      new_entries =
        data.entries
        |> Enum.reject(&MapSet.member?(existing_seeds, &1.seed))
        |> Enum.map(fn e ->
          %{
            seed: e.seed,
            model: e.model,
            failure_type: to_atom_safe(e.failure_type),
            check_name: to_atom_safe(e.check_name),
            tags: Enum.map(e.tags || [], &to_atom_safe/1),
            description: e.description,
            discovered_at: DateTime.to_iso8601(DateTime.utc_now()),
            last_run: nil,
            status: to_status_atom(e.status),
            run_count: 0,
            fail_count: 0,
            dependency_versions: atomize_dep_versions(e[:dependency_versions] || %{})
          }
        end)

      {:ok, %{library | entries: library.entries ++ new_entries}, length(new_entries)}
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
      failing: Enum.count(entries, &(&1.status == :failing)),
      fixed: Enum.count(entries, &(&1.status == :fixed)),
      flaky: Enum.count(entries, &(&1.status == :flaky)),
      unknown: Enum.count(entries, &(&1.status == :unknown)),
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

    header = """
    Seed Library: #{stats.total} seeds
    ├── Failing: #{stats.failing}
    ├── Fixed: #{stats.fixed}
    ├── Flaky: #{stats.flaky}
    └── Unknown: #{stats.unknown}
    """

    entries_str =
      library.entries
      |> Enum.sort_by(& &1.discovered_at, :desc)
      |> Enum.take(10)
      |> Enum.map_join("\n", fn e ->
        tags_str = if e.tags != [], do: " [#{Enum.join(e.tags, ", ")}]", else: ""
        status_icon = status_icon(e.status)
        "  #{status_icon} #{e.seed} - #{e.failure_type}#{tags_str}"
      end)

    header <> "\nRecent entries:\n" <> entries_str
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_filter_status(entries, nil), do: entries
  defp maybe_filter_status(entries, status), do: Enum.filter(entries, &(&1.status == status))

  defp maybe_filter_tags(entries, []), do: entries

  defp maybe_filter_tags(entries, tags) do
    tag_set = MapSet.new(tags)
    Enum.filter(entries, fn e -> MapSet.subset?(tag_set, MapSet.new(e.tags)) end)
  end

  defp maybe_filter_model(entries, nil), do: entries

  defp maybe_filter_model(entries, model) do
    Enum.filter(entries, &String.contains?(&1.model, model))
  end

  defp to_status_atom("failing"), do: :failing
  defp to_status_atom("fixed"), do: :fixed
  defp to_status_atom("flaky"), do: :flaky
  defp to_status_atom("unknown"), do: :unknown
  defp to_status_atom(atom) when is_atom(atom), do: atom
  defp to_status_atom(_), do: :unknown

  defp to_atom_safe(nil), do: nil
  defp to_atom_safe(atom) when is_atom(atom), do: atom
  defp to_atom_safe(string) when is_binary(string), do: String.to_atom(string)

  defp atomize_dep_versions(nil), do: %{}

  defp atomize_dep_versions(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_atom_safe(k), v} end)
  end

  defp status_icon(:failing), do: "x"
  defp status_icon(:fixed), do: "o"
  defp status_icon(:flaky), do: "~"
  defp status_icon(_), do: "?"
end
