defmodule PropertyDamage.FailureIntelligence do
  @moduledoc """
  Failure Intelligence - Pattern detection and fix verification for failures.

  This module provides tools for:
  - **Fingerprinting**: Extract comparable features from failures
  - **Similarity**: Compare failures and identify duplicates
  - **Pattern Detection**: Cluster similar failures to find root causes
  - **Fix Verification**: Replay the shrunk sequence of a failure against a fix
  - **Exploration**: Sample plans from seeds near a failure's seed

  ## Quick Start

      # Analyze a set of failures
      failures = [failure1, failure2, failure3]
      analysis = PropertyDamage.FailureIntelligence.analyze(failures)

      # Check if two failures are similar
      similar? = PropertyDamage.FailureIntelligence.similar?(failure1, failure2)

      # Verify a fix by replaying the shrunk sequence
      result = PropertyDamage.FailureIntelligence.verify_fix(failure, MyModel,
        targets: [{MyAdapter, config: %{}}]
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

  When you believe a bug is fixed, replay the shrunk sequence of its report:

      result = PropertyDamage.FailureIntelligence.verify_fix(failure, MyModel,
        targets: [MyAdapter]
      )

      case result do
        {:error, :no_replay_artifact} -> "The report holds no replay artifact"
        %{status: :verified} -> "The shrunk sequence no longer fails"
        %{status: :still_failing} -> "The recorded failure still occurs"
        %{status: :different_failure} -> "The sequence fails with another failure"
      end

  Verification never draws a plan from a seed, so a change to generation cannot
  hide a failing sequence.
  """

  alias PropertyDamage.FailureIntelligence.{
    Exploration,
    Fingerprint,
    Patterns,
    Similarity,
    Verification
  }

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
      # => %Fingerprint{kind: :check_failed, check_name: :balance_valid, ...}
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
      #   breakdown: %{kind: 1.0, check_name: 1.0, command_type: 0.8, ...},
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
  Verifies a fix by replaying the shrunk sequence of a failure report.

  The replay artifact in `report.replay` holds the shrunk commands and the
  signature of the failure. This function replays those commands against the
  fixed system and compares the signature of what happens with the recorded
  one. It never draws a plan from a seed.

  ## Options

  - `:targets` - A list with exactly one entry (required): the adapter to
    replay against, as a module or `{AdapterModule, config: map}`; see
    `PropertyDamage.Target`

  ## Example

      result = PropertyDamage.FailureIntelligence.verify_fix(failure, MyModel,
        targets: [{MyAdapter, config: %{base_url: "http://localhost:4000"}}]
      )

      case result do
        {:error, :no_replay_artifact} ->
          IO.puts("This report has no replay artifact. Capture the failure again.")

        %{status: :verified} ->
          IO.puts("The shrunk sequence no longer fails")

        %{status: :still_failing} ->
          IO.puts("The recorded failure still occurs")

        %{status: :different_failure, new_signature: signature} ->
          IO.puts("The fix moved the failure: \#{inspect(signature)}")
      end

  ## Return Value

  A report whose `replay` is `nil` or `{:refused, _}` returns
  `{:error, :no_replay_artifact}`. Any other report returns:

      %{
        status: :verified | :still_failing | :different_failure,
        signature: {:check_failed, :balance_valid, 0},
        failure: nil | %PropertyDamage.FailureReport{},
        summary: "Fix verified. The shrunk sequence replays without a failure."
      }

  A `:different_failure` result also carries `new_signature`.
  """
  @spec verify_fix(FailureReport.t(), module(), keyword()) ::
          verification_result() | {:error, :no_replay_artifact}
  defdelegate verify_fix(report, model, opts \\ []), to: Verification

  @doc """
  Verifies several fixes at once.

  Returns `[{report, result_or_error}]`. To verify a cluster, pass the reports
  of its members.

  ## Example

      results = PropertyDamage.FailureIntelligence.verify_fixes(failures, MyModel,
        targets: [MyAdapter]
      )

      Enum.each(results, fn
        {failure, %{status: status}} -> IO.puts("Seed \#{failure.seed}: \#{status}")
        {failure, {:error, reason}} -> IO.puts("Seed \#{failure.seed}: \#{reason}")
      end)
  """
  @spec verify_fixes([FailureReport.t()], module(), keyword()) :: [
          {FailureReport.t(), verification_result() | {:error, :no_replay_artifact}}
        ]
  defdelegate verify_fixes(reports, model, opts \\ []), to: Verification

  @doc """
  Runs plans drawn from seeds near the seed of a failure report.

  This samples other plans and gives no verification verdict: a passing seed
  says nothing about the shrunk sequence. Use `verify_fix/3` to check a fix.

  ## Options

  - `:targets` - A list with exactly one entry (required); see
    `PropertyDamage.Target`
  - `:max_seeds` - Maximum number of seeds to run (default: 10)
  - `:seed_range` - Width of the range of seeds around the original seed
    (default: 1000)

  ## Example

      result = PropertyDamage.FailureIntelligence.explore_neighbouring_seeds(failure, MyModel,
        targets: [MyAdapter],
        max_seeds: 20
      )

      Enum.each(result.failures, fn %{seed: seed, report: report} ->
        IO.puts("Seed \#{seed} fails: \#{inspect(report.failure_reason)}")
      end)

  ## Return Value

  A map with `original_seed`, `seeds_run`, `passed` and `failures`, a list of
  `%{seed: seed, report: report}` for each seed whose run fails.
  """
  @spec explore_neighbouring_seeds(FailureReport.t(), module(), keyword()) ::
          Exploration.result()
  defdelegate explore_neighbouring_seeds(report, model, opts \\ []), to: Exploration

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
