defmodule PropertyDamage.FailureIntelligence do
  @moduledoc """
  Failure Intelligence - Pattern detection and fix verification for failures.

  This module provides tools for:
  - **Fingerprinting**: Extract comparable features from failures
  - **Similarity**: Compare failures and identify duplicates
  - **Pattern Detection**: Cluster similar failures to find root causes
  - **Fix Verification**: Confirm fixes are robust with seed variations

  ## Quick Start

      # Analyze a set of failures
      failures = [failure1, failure2, failure3]
      analysis = PropertyDamage.FailureIntelligence.analyze(failures)

      # Check if two failures are similar
      similar? = PropertyDamage.FailureIntelligence.similar?(failure1, failure2)

      # Verify a fix is robust
      result = PropertyDamage.FailureIntelligence.verify_fix(failure, MyModel,
        adapter: MyAdapter,
        adapter_config: %{}
      )

  ## Pattern Detection

  The system uses fingerprinting to extract key characteristics:
  - Failure type (check failure, exception, timeout, etc.)
  - Check name that failed
  - Command type that triggered the failure
  - Event types produced
  - Error category and pattern

  Similar failures are clustered together to identify systemic issues.

  ## Fix Verification

  When you believe a bug is fixed, verify it:

      result = PropertyDamage.FailureIntelligence.verify_fix(failure, MyModel,
        adapter: MyAdapter,
        max_variations: 20
      )

      case result.status do
        :verified -> "Fix confirmed with high confidence"
        :still_failing -> "Original failure still reproduces"
        :partially_fixed -> "Some variations still fail"
        :flaky -> "Intermittent failures detected"
      end
  """

  alias PropertyDamage.FailureIntelligence.{Fingerprint, Patterns, Similarity, Verification}
  alias PropertyDamage.FailureReport

  @type analysis :: Patterns.analysis()
  @type verification_result :: Verification.verification_result()

  # ============================================================================
  # Fingerprinting
  # ============================================================================

  @doc """
  Creates a fingerprint from a failure report.

  A fingerprint captures the essential characteristics of a failure for comparison.

  ## Example

      fingerprint = PropertyDamage.FailureIntelligence.fingerprint(failure)
      # => %Fingerprint{failure_type: :check_failed, check_name: :balance_valid, ...}
  """
  @spec fingerprint(FailureReport.t()) :: Fingerprint.t()
  defdelegate fingerprint(failure), to: Fingerprint, as: :from_failure_report

  @doc """
  Returns a short hash of a fingerprint for display.

  ## Example

      hash = PropertyDamage.FailureIntelligence.fingerprint_hash(failure)
      # => "a1b2c3d4"
  """
  @spec fingerprint_hash(FailureReport.t()) :: String.t()
  def fingerprint_hash(%FailureReport{} = failure) do
    failure
    |> Fingerprint.from_failure_report()
    |> Fingerprint.short_hash()
  end

  # ============================================================================
  # Similarity
  # ============================================================================

  @doc """
  Computes the similarity score between two failures.

  Returns a score between 0.0 (completely different) and 1.0 (identical).

  ## Example

      score = PropertyDamage.FailureIntelligence.similarity_score(failure1, failure2)
      # => 0.85
  """
  @spec similarity_score(FailureReport.t(), FailureReport.t()) :: float()
  def similarity_score(%FailureReport{} = f1, %FailureReport{} = f2) do
    fp1 = Fingerprint.from_failure_report(f1)
    fp2 = Fingerprint.from_failure_report(f2)
    Similarity.score(fp1, fp2)
  end

  @doc """
  Checks if two failures are similar (score >= 0.70).

  ## Example

      if PropertyDamage.FailureIntelligence.similar?(failure1, failure2) do
        IO.puts("These failures likely have the same root cause")
      end
  """
  @spec similar?(FailureReport.t(), FailureReport.t()) :: boolean()
  def similar?(%FailureReport{} = f1, %FailureReport{} = f2) do
    similarity_score(f1, f2) >= 0.70
  end

  @doc """
  Checks if two failures are similar using a custom threshold.
  """
  @spec similar?(FailureReport.t(), FailureReport.t(), float()) :: boolean()
  def similar?(%FailureReport{} = f1, %FailureReport{} = f2, threshold) do
    similarity_score(f1, f2) >= threshold
  end

  @doc """
  Performs a detailed comparison between two failures.

  Returns the overall score, per-component breakdown, and similarity determination.

  ## Example

      comparison = PropertyDamage.FailureIntelligence.compare(failure1, failure2)
      # => %{
      #   score: 0.85,
      #   breakdown: %{failure_type: 1.0, check_name: 1.0, command_type: 0.8, ...},
      #   is_similar: true
      # }
  """
  @spec compare(FailureReport.t(), FailureReport.t()) :: Similarity.comparison()
  def compare(%FailureReport{} = f1, %FailureReport{} = f2) do
    fp1 = Fingerprint.from_failure_report(f1)
    fp2 = Fingerprint.from_failure_report(f2)
    Similarity.compare(fp1, fp2)
  end

  @doc """
  Finds failures similar to the target from a list.

  ## Options

  - `:threshold` - Minimum similarity score (default: 0.70)
  - `:limit` - Maximum number of results (default: unlimited)

  ## Example

      similar = PropertyDamage.FailureIntelligence.find_similar(failure, all_failures,
        threshold: 0.80,
        limit: 5
      )
      # => [{similar_failure1, 0.92}, {similar_failure2, 0.85}, ...]
  """
  @spec find_similar(FailureReport.t(), [FailureReport.t()], keyword()) ::
          [{FailureReport.t(), float()}]
  def find_similar(%FailureReport{} = target, failures, opts \\ []) do
    target_fp = Fingerprint.from_failure_report(target)

    failures
    |> Enum.map(fn f ->
      fp = Fingerprint.from_failure_report(f)
      {f, Similarity.score(target_fp, fp)}
    end)
    |> filter_and_sort_similar(opts)
  end

  defp filter_and_sort_similar(results, opts) do
    threshold = Keyword.get(opts, :threshold, 0.70)
    limit = Keyword.get(opts, :limit)

    filtered =
      results
      |> Enum.filter(fn {_f, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_f, score} -> score end, :desc)

    if limit, do: Enum.take(filtered, limit), else: filtered
  end

  # ============================================================================
  # Pattern Detection
  # ============================================================================

  @doc """
  Analyzes a set of failures to identify patterns.

  Returns clustering information and pattern summaries.

  ## Options

  - `:threshold` - Similarity threshold for clustering (default: 0.70)
  - `:min_cluster_size` - Minimum size for a pattern cluster (default: 2)

  ## Example

      analysis = PropertyDamage.FailureIntelligence.analyze(failures)

      IO.puts(analysis.pattern_summary)
      # => "Analyzed 15 failures:
      #     - 3 distinct patterns (12 failures)
      #     - 3 unique failures (no pattern match)
      #
      #     Top patterns:
      #       - Check failure in :balance_valid during DebitAccount (5 occurrences)
      #       - Invariant violation during CreditAccount (4 occurrences)"

      # Get specific patterns
      Enum.each(analysis.clusters, fn cluster ->
        IO.puts("Pattern: \#{cluster.pattern.description}")
        IO.puts("Occurrences: \#{cluster.size}")
      end)
  """
  @spec analyze([FailureReport.t()], keyword()) :: analysis()
  defdelegate analyze(failures, opts \\ []), to: Patterns

  @doc """
  Clusters failures by similarity.

  Returns a list of clusters, each containing similar failures.

  ## Example

      clusters = PropertyDamage.FailureIntelligence.cluster(failures)
      Enum.each(clusters, fn c ->
        IO.puts("Cluster \#{c.id}: \#{c.size} failures")
      end)
  """
  @spec cluster([FailureReport.t()], keyword()) :: [Patterns.cluster()]
  defdelegate cluster(failures, opts \\ []), to: Patterns, as: :cluster_failures

  @doc """
  Checks if a failure matches an existing pattern cluster.

  ## Example

      case PropertyDamage.FailureIntelligence.match_pattern(new_failure, clusters) do
        nil -> IO.puts("New unique failure")
        cluster -> IO.puts("Matches pattern: \#{cluster.pattern.description}")
      end
  """
  @spec match_pattern(FailureReport.t(), [Patterns.cluster()], keyword()) ::
          Patterns.cluster() | nil
  defdelegate match_pattern(failure, clusters, opts \\ []), to: Patterns

  # ============================================================================
  # Fix Verification
  # ============================================================================

  @doc """
  Verifies that a fix is robust by testing the original seed and variations.

  This helps ensure that:
  1. The original failure no longer reproduces
  2. Similar command sequences also pass
  3. The fix is robust across different conditions

  ## Options

  - `:adapter` - The adapter module to use (required)
  - `:adapter_config` - Configuration for the adapter
  - `:max_variations` - Maximum number of seed variations to test (default: 10)
  - `:variation_range` - Range for generating seed variations (default: 1000)

  ## Example

      result = PropertyDamage.FailureIntelligence.verify_fix(failure, MyModel,
        adapter: MyAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        max_variations: 20
      )

      case result.status do
        :verified ->
          IO.puts("Fix verified with \#{result.confidence * 100}% confidence")

        :still_failing ->
          IO.puts("Original failure still reproduces!")

        :partially_fixed ->
          IO.puts("Fix incomplete. \#{result.variations_failed} variations still fail")

        :flaky ->
          IO.puts("Intermittent failures detected. May be timing-related.")
      end

  ## Return Value

      %{
        status: :verified | :still_failing | :partially_fixed | :flaky,
        original_seed: 12345,
        original_passes: true,
        variations_run: 20,
        variations_passed: 18,
        variations_failed: 2,
        failed_variations: [12346, 12400],
        confidence: 0.95,
        summary: "Fix verified! Original seed and all 18 variations pass."
      }
  """
  @spec verify_fix(FailureReport.t(), module(), keyword()) :: verification_result()
  defdelegate verify_fix(failure, model, opts \\ []), to: Verification

  @doc """
  Verifies multiple fixes at once.

  Useful for batch verification after a series of bug fixes.

  ## Example

      results = PropertyDamage.FailureIntelligence.verify_fixes(failures, MyModel,
        adapter: MyAdapter
      )

      Enum.each(results, fn {failure, result} ->
        IO.puts("Seed \#{failure.seed}: \#{result.status}")
      end)
  """
  @spec verify_fixes([FailureReport.t()], module(), keyword()) :: [
          {FailureReport.t(), verification_result()}
        ]
  defdelegate verify_fixes(failures, model, opts \\ []), to: Verification

  @doc """
  Quick check if a single seed still fails.

  ## Example

      if PropertyDamage.FailureIntelligence.still_fails?(12345, MyModel, MyAdapter) do
        IO.puts("Bug not fixed yet!")
      end
  """
  @spec still_fails?(integer(), module(), module(), map()) :: boolean()
  defdelegate still_fails?(seed, model, adapter, adapter_config \\ %{}), to: Verification

  @doc """
  Formats a verification result for display.

  ## Example

      result = PropertyDamage.FailureIntelligence.verify_fix(failure, model, opts)
      IO.puts(PropertyDamage.FailureIntelligence.format_verification(result))
  """
  @spec format_verification(verification_result()) :: String.t()
  defdelegate format_verification(result), to: Verification, as: :format_result

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  @doc """
  Returns a summary of failure intelligence analysis.

  Combines pattern detection with fix suggestions.

  ## Example

      summary = PropertyDamage.FailureIntelligence.summary(failures)
      IO.puts(summary)
  """
  @spec summary([FailureReport.t()]) :: String.t()
  def summary(failures) when is_list(failures) do
    analysis = analyze(failures)
    analysis.pattern_summary
  end

  @doc """
  Finds potential duplicate failures (similarity > 0.90).

  ## Example

      dupes = PropertyDamage.FailureIntelligence.find_duplicates(failures)
      Enum.each(dupes, fn {f1, f2, score} ->
        IO.puts("Seeds \#{f1.seed} and \#{f2.seed} are \#{score * 100}% similar")
      end)
  """
  @spec find_duplicates([FailureReport.t()]) :: [{FailureReport.t(), FailureReport.t(), float()}]
  def find_duplicates(failures) do
    indexed = Enum.with_index(failures)

    for {f1, i} <- indexed,
        {f2, j} <- indexed,
        i < j,
        score = similarity_score(f1, f2),
        score >= 0.90 do
      {f1, f2, score}
    end
    |> Enum.sort_by(fn {_, _, score} -> score end, :desc)
  end

  @doc """
  Groups failures by their fingerprint hash for quick deduplication.

  ## Example

      groups = PropertyDamage.FailureIntelligence.group_by_fingerprint(failures)
      Enum.each(groups, fn {hash, group} ->
        IO.puts("Hash \#{hash}: \#{length(group)} failures")
      end)
  """
  @spec group_by_fingerprint([FailureReport.t()]) :: %{String.t() => [FailureReport.t()]}
  def group_by_fingerprint(failures) do
    Enum.group_by(failures, &fingerprint_hash/1)
  end
end
