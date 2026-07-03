defmodule PropertyDamage.Regression do
  @moduledoc """
  Automatic regression test management for PropertyDamage.

  When PropertyDamage discovers a failure, this module can automatically:
  - Save failure files for later analysis
  - Add seeds to a seed library for regression testing
  - Generate ExUnit tests for CI/CD
  - Deduplicate similar failures to avoid noise

  ## Usage with run/1

  The simplest way to use regression management is via the `:regression` option:

      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        regression: [
          save_failures: "failures/",
          seed_library: "seeds.json",
          generate_tests: "test/regressions/",
          tags: [:auto_detected],
          dedup: true
        ]
      )

  ## Using on_failure Callback

  You can also use the `handler/1` function with `:on_failure`:

      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        on_failure: PropertyDamage.Regression.handler([
          save_failures: "failures/",
          seed_library: "seeds.json"
        ])
      )

  ## Composing Handlers

  For custom behavior, compose multiple handlers:

      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        on_failure: PropertyDamage.Regression.compose([
          PropertyDamage.Regression.save_failure("failures/"),
          PropertyDamage.Regression.add_to_library("seeds.json"),
          fn report -> Logger.warning("Failure: \#{report.seed}") end
        ])
      )

  ## Deduplication

  When `dedup: true` is set, failures are checked against existing failures
  before being added. This prevents noise from multiple runs finding the
  same underlying bug.

      regression: [
        save_failures: "failures/",
        dedup: true,
        dedup_threshold: 0.90  # 90% similarity threshold
      ]
  """

  alias PropertyDamage.{Export, FailureIntelligence, FailureReport, Persistence, SeedLibrary}

  @type handler :: (FailureReport.t() -> any())

  @type regression_opts :: [
          save_failures: Path.t(),
          seed_library: Path.t(),
          generate_tests: Path.t(),
          tags: [atom()],
          description: String.t() | nil,
          dedup: boolean(),
          dedup_threshold: float(),
          dedup_source: :failures,
          verbose: boolean(),
          adapter: module() | nil
        ]

  @default_dedup_threshold 0.90

  # ============================================================================
  # Main API
  # ============================================================================

  @doc """
  Creates a handler function from regression options.

  This is the main entry point for creating regression handlers.
  The returned function can be passed to `:on_failure` in `PropertyDamage.run/1`.

  ## Options

  - `:save_failures` - Directory to save failure files
  - `:seed_library` - Path to seed library JSON file
  - `:generate_tests` - Directory to generate ExUnit test files
  - `:tags` - Tags to add to seed library entries (default: `[:auto_detected]`)
  - `:description` - Optional description for seed library entries
  - `:dedup` - Enable deduplication (default: false)
  - `:dedup_threshold` - Similarity threshold for dedup (default: 0.90)
  - `:dedup_source` - Where to check for duplicates. Only `:failures` (saved
    failure files) is supported.
  - `:verbose` - Print actions taken (default: false)
  - `:adapter` - Adapter module for generated-test HTTP-spec mapping

  ## Example

      handler = PropertyDamage.Regression.handler(
        save_failures: "failures/",
        seed_library: "seeds.json",
        dedup: true,
        verbose: true
      )

      PropertyDamage.run(model: M, adapter: A, on_failure: handler)
  """
  @spec handler(regression_opts()) :: handler()
  def handler(opts \\ []) do
    # Validate at factory time so a typo'd option raises here, not silently
    # hours into a run when the handler first fires.
    opts = PropertyDamage.Options.validate_regression_opts!(opts)

    fn failure_report ->
      handle_failure(failure_report, opts)
    end
  end

  @doc """
  Processes a failure according to regression options.

  Returns a summary of actions taken.

  ## Example

      result = PropertyDamage.Regression.handle_failure(failure, [
        save_failures: "failures/",
        seed_library: "seeds.json"
      ])

      # => %{
      #   saved_failure: {:ok, "failures/..."},
      #   added_to_library: {:ok, "seeds.json"},
      #   generated_test: nil,
      #   skipped: false,
      #   skip_reason: nil
      # }
  """
  @spec handle_failure(FailureReport.t(), regression_opts()) :: map()
  def handle_failure(%FailureReport{} = failure, opts \\ []) do
    opts = PropertyDamage.Options.validate_regression_opts!(opts)
    verbose = Keyword.get(opts, :verbose, false)
    dedup = Keyword.get(opts, :dedup, false)

    # Check for duplicates first
    {should_skip, skip_reason} =
      if dedup do
        check_duplicate(failure, opts)
      else
        {false, nil}
      end

    if should_skip do
      if verbose do
        IO.puts("[Regression] Skipping duplicate failure (seed: #{failure.seed})")
      end

      %{
        saved_failure: nil,
        added_to_library: nil,
        generated_test: nil,
        skipped: true,
        skip_reason: skip_reason
      }
    else
      results = %{
        saved_failure: maybe_save_failure(failure, opts, verbose),
        added_to_library: maybe_add_to_library(failure, opts, verbose),
        generated_test: maybe_generate_test(failure, opts, verbose),
        skipped: false,
        skip_reason: nil
      }

      if verbose do
        print_summary(results, failure)
      end

      results
    end
  end

  # ============================================================================
  # Individual Handlers
  # ============================================================================

  @doc """
  Creates a handler that saves failures to a directory.

  ## Example

      PropertyDamage.run(
        model: M,
        adapter: A,
        on_failure: PropertyDamage.Regression.save_failure("failures/")
      )
  """
  @spec save_failure(Path.t(), keyword()) :: handler()
  def save_failure(directory, opts \\ []) do
    opts = PropertyDamage.Options.validate_regression_save_failure!(opts)

    fn failure_report ->
      Persistence.save(failure_report, directory, opts)
    end
  end

  @doc """
  Creates a handler that adds failures to a seed library.

  ## Options

  - `:tags` - Tags to add to the entry (default: `[:auto_detected]`)
  - `:description` - Optional description

  ## Example

      PropertyDamage.run(
        model: M,
        adapter: A,
        on_failure: PropertyDamage.Regression.add_to_library("seeds.json",
          tags: [:balance_bug]
        )
      )
  """
  @spec add_to_library(Path.t(), keyword()) :: handler()
  def add_to_library(path, opts \\ []) do
    opts = PropertyDamage.Options.validate_regression_add_to_library!(opts)

    fn failure_report ->
      do_add_to_library(failure_report, path, opts)
    end
  end

  @doc """
  Creates a handler that generates ExUnit regression tests.

  Options are the ExUnit export options (validated at factory time via the same
  schema as `PropertyDamage.Export.to_exunit/2`): `:adapter`, `:model`,
  `:module_name`, `:test_name`, `:adapter_config`, `:expect_fixed`.

  ## Example

      PropertyDamage.run(
        model: M,
        adapter: A,
        on_failure: PropertyDamage.Regression.generate_test("test/regressions/",
          adapter: MyHTTPAdapter
        )
      )
  """
  @spec generate_test(Path.t(), keyword()) :: handler()
  def generate_test(directory, opts \\ []) do
    # generate_test only produces :exunit; validate against that surface at
    # factory time (reusing Export's schema) so bad options fail fast instead
    # of being swallowed by compose/1 when the handler eventually fires.
    opts = PropertyDamage.Options.validate_export_exunit!(opts)

    fn failure_report ->
      Export.save(failure_report, directory, :exunit, opts)
    end
  end

  @doc """
  Composes multiple handlers into a single handler.

  All handlers are called in order. Errors in one handler don't prevent
  subsequent handlers from running.

  ## Example

      PropertyDamage.run(
        model: M,
        adapter: A,
        on_failure: PropertyDamage.Regression.compose([
          PropertyDamage.Regression.save_failure("failures/"),
          PropertyDamage.Regression.add_to_library("seeds.json"),
          fn report -> IO.puts("Found: \#{report.seed}") end
        ])
      )
  """
  @spec compose([handler()]) :: handler()
  def compose(handlers) when is_list(handlers) do
    fn failure_report ->
      Enum.map(handlers, fn handler ->
        try do
          {:ok, handler.(failure_report)}
        rescue
          e -> {:error, e}
        end
      end)
    end
  end

  # ============================================================================
  # Deduplication
  # ============================================================================

  @doc """
  Checks if a failure is a duplicate of an existing failure.

  Returns `{true, reason}` if duplicate, `{false, nil}` otherwise.

  ## Options

  - `:dedup_threshold` - Similarity threshold (default: 0.90)
  - `:save_failures` - Directory containing saved failures to compare against
  """
  @spec check_duplicate(FailureReport.t(), keyword()) :: {boolean(), term()}
  def check_duplicate(%FailureReport{} = failure, opts) do
    opts = PropertyDamage.Options.validate_regression_opts!(opts)
    threshold = Keyword.get(opts, :dedup_threshold, @default_dedup_threshold)

    existing_failures = load_existing_failures(opts)

    case find_duplicate(failure, existing_failures, threshold) do
      nil ->
        {false, nil}

      {similar_failure, score} ->
        {true, {:similar_to, similar_failure.seed, score}}
    end
  end

  @doc """
  Finds a duplicate failure from a list.

  Returns `{similar_failure, score}` if found, `nil` otherwise.
  """
  @spec find_duplicate(FailureReport.t(), [FailureReport.t()], float()) ::
          {FailureReport.t(), float()} | nil
  def find_duplicate(_failure, [], _threshold), do: nil

  def find_duplicate(%FailureReport{} = failure, existing, threshold) do
    case FailureIntelligence.find_similar(failure, existing, threshold: threshold, limit: 1) do
      [{similar, score} | _] -> {similar, score}
      [] -> nil
    end
  end

  # ============================================================================
  # Batch Operations
  # ============================================================================

  @doc """
  Processes multiple failures, deduplicating across the batch.

  Useful when you have accumulated failures and want to add only unique ones.

  ## Example

      failures = [failure1, failure2, failure3]
      results = PropertyDamage.Regression.process_batch(failures, [
        seed_library: "seeds.json",
        dedup: true
      ])
  """
  @spec process_batch([FailureReport.t()], regression_opts()) :: [map()]
  def process_batch(failures, opts \\ []) do
    opts = PropertyDamage.Options.validate_regression_opts!(opts)
    dedup = Keyword.get(opts, :dedup, false)
    threshold = Keyword.get(opts, :dedup_threshold, @default_dedup_threshold)

    {results, _seen} =
      Enum.reduce(failures, {[], []}, fn failure, {results, seen} ->
        # Check against both existing failures and already-processed ones
        is_dup =
          dedup and
            (find_duplicate(failure, seen, threshold) != nil or
               elem(check_duplicate(failure, opts), 0))

        if is_dup do
          result = %{
            seed: failure.seed,
            saved_failure: nil,
            added_to_library: nil,
            generated_test: nil,
            skipped: true,
            skip_reason: :duplicate
          }

          {[result | results], seen}
        else
          result = handle_failure(failure, Keyword.put(opts, :dedup, false))
          result = Map.put(result, :seed, failure.seed)
          {[result | results], [failure | seen]}
        end
      end)

    Enum.reverse(results)
  end

  @doc """
  Generates a summary report for batch processing results.
  """
  @spec batch_summary([map()]) :: map()
  def batch_summary(results) do
    total = length(results)
    skipped = Enum.count(results, & &1.skipped)
    processed = total - skipped

    saved = Enum.count(results, fn r -> r.saved_failure && match?({:ok, _}, r.saved_failure) end)

    added =
      Enum.count(results, fn r -> r.added_to_library && match?({:ok, _}, r.added_to_library) end)

    generated =
      Enum.count(results, fn r -> r.generated_test && match?({:ok, _}, r.generated_test) end)

    %{
      total: total,
      processed: processed,
      skipped: skipped,
      saved_failures: saved,
      added_to_library: added,
      generated_tests: generated
    }
  end

  @doc """
  Formats batch summary for display.
  """
  @spec format_batch_summary(map()) :: String.t()
  def format_batch_summary(summary) do
    """
    Regression Batch Summary
    ========================
    Total failures: #{summary.total}
    Processed: #{summary.processed}
    Skipped (duplicates): #{summary.skipped}

    Actions:
      Saved failures: #{summary.saved_failures}
      Added to library: #{summary.added_to_library}
      Generated tests: #{summary.generated_tests}
    """
    |> String.trim()
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp maybe_save_failure(failure, opts, verbose) do
    case Keyword.get(opts, :save_failures) do
      nil ->
        nil

      directory ->
        result = Persistence.save(failure, directory)

        if verbose do
          case result do
            {:ok, path} -> IO.puts("[Regression] Saved failure to: #{path}")
            {:error, reason} -> IO.puts("[Regression] Failed to save: #{inspect(reason)}")
          end
        end

        result
    end
  end

  defp maybe_add_to_library(failure, opts, verbose) do
    case Keyword.get(opts, :seed_library) do
      nil ->
        nil

      path ->
        result = do_add_to_library(failure, path, opts)

        if verbose do
          case result do
            {:ok, _} ->
              IO.puts("[Regression] Added seed #{failure.seed} to: #{path}")

            {:error, reason} ->
              IO.puts("[Regression] Failed to add to library: #{inspect(reason)}")
          end
        end

        result
    end
  end

  defp maybe_generate_test(failure, opts, verbose) do
    case Keyword.get(opts, :generate_tests) do
      nil ->
        nil

      directory ->
        # Only :adapter applies to :exunit generation; :base_url is a
        # script/livebook concern and is not part of the regression surface.
        export_opts = Keyword.take(opts, [:adapter])

        result = Export.save(failure, directory, :exunit, export_opts)

        if verbose do
          case result do
            {:ok, path} ->
              IO.puts("[Regression] Generated test: #{path}")

            {:error, reason} ->
              IO.puts("[Regression] Failed to generate test: #{inspect(reason)}")
          end
        end

        result
    end
  end

  defp do_add_to_library(failure, path, opts) do
    tags = Keyword.get(opts, :tags, [:auto_detected])
    description = Keyword.get(opts, :description)

    # Load or create library
    library =
      case SeedLibrary.load(path) do
        {:ok, lib} -> lib
        {:error, _} -> SeedLibrary.new()
      end

    # Add failure
    case SeedLibrary.add(library, failure, tags: tags, description: description) do
      {:ok, updated_library} ->
        case SeedLibrary.save(updated_library, path) do
          :ok -> {:ok, path}
          error -> error
        end

      error ->
        error
    end
  end

  # Dedup compares against saved failure files only. A seed library entry stores
  # just a seed, not a comparable failure signature, so it is not a dedup source
  # (DR-023); durable comparison material lives in saved `.pd` files / exports.
  defp load_existing_failures(opts) do
    case Keyword.get(opts, :save_failures) do
      nil -> []
      dir -> load_failures_from_directory(dir)
    end
  end

  defp load_failures_from_directory(directory) do
    # Persistence.list returns a list directly, not {:ok, list}
    directory
    |> Persistence.list()
    |> Enum.map(fn meta -> Map.get(meta, :path) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Persistence.load/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, f} -> f end)
  end

  defp print_summary(results, failure) do
    IO.puts("")
    IO.puts("[Regression] Processed failure (seed: #{failure.seed})")

    actions =
      [
        results.saved_failure && "saved",
        results.added_to_library && "added to library",
        results.generated_test && "generated test"
      ]
      |> Enum.reject(&is_nil/1)

    if actions != [] do
      IO.puts("[Regression] Actions: #{Enum.join(actions, ", ")}")
    end

    IO.puts("")
  end
end
