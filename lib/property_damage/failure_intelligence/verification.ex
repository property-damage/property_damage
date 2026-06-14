defmodule PropertyDamage.FailureIntelligence.Verification do
  @moduledoc """
  Fix verification mode for confirming that fixes are robust.

  Runs the original failing seed and variations to ensure:
  1. The original failure no longer reproduces
  2. Similar command sequences also pass
  3. The fix is robust across different conditions
  """

  alias PropertyDamage.FailureIntelligence.{Fingerprint, Patterns}
  alias PropertyDamage.FailureReport

  @type verification_result :: %{
          status: :verified | :still_failing | :partially_fixed | :flaky,
          original_seed: integer(),
          original_passes: boolean(),
          variations_run: non_neg_integer(),
          variations_passed: non_neg_integer(),
          variations_failed: non_neg_integer(),
          failed_variations: [integer()],
          similar_failures: [FailureReport.t()],
          confidence: float(),
          summary: String.t()
        }

  @type options :: [
          adapter: module(),
          adapter_config: map(),
          max_variations: non_neg_integer(),
          variation_range: integer(),
          include_similar: boolean(),
          similar_threshold: float()
        ]

  @default_max_variations 10
  @default_variation_range 1000

  @doc """
  Verifies that a fix is robust by testing the original seed and variations.

  ## Options

  - `:adapter` - The adapter module to use (required)
  - `:adapter_config` - Configuration for the adapter
  - `:max_variations` - Maximum number of seed variations to test (default: 10)
  - `:variation_range` - Range for generating seed variations (default: 1000)
  - `:include_similar` - Whether to test similar failure patterns (default: true)
  - `:similar_threshold` - Threshold for similarity matching (default: 0.80)
  """
  @spec verify_fix(FailureReport.t(), module(), options()) :: verification_result()
  def verify_fix(%FailureReport{} = failure, model, opts \\ []) do
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    max_variations = Keyword.get(opts, :max_variations, @default_max_variations)
    variation_range = Keyword.get(opts, :variation_range, @default_variation_range)

    # Test original seed
    original_result = run_seed(failure.seed, model, adapter, adapter_config)

    # Generate and test variations
    variations = generate_variations(failure.seed, max_variations, variation_range)

    variation_results =
      Enum.map(variations, fn seed ->
        {seed, run_seed(seed, model, adapter, adapter_config)}
      end)

    # Collect similar failures if any variations fail
    similar_failures =
      variation_results
      |> Enum.filter(fn {_seed, result} -> match?({:error, _}, result) end)
      |> Enum.map(fn {_seed, {:error, report}} -> report end)

    # Calculate results
    passed_variations =
      Enum.count(variation_results, fn {_seed, result} -> result == :ok end)

    failed_variations =
      Enum.filter(variation_results, fn {_seed, result} -> match?({:error, _}, result) end)
      |> Enum.map(fn {seed, _} -> seed end)

    build_result(
      failure.seed,
      original_result,
      passed_variations,
      failed_variations,
      similar_failures,
      length(variations)
    )
  end

  @doc """
  Verifies multiple fixes at once, useful for batch verification.
  """
  @spec verify_fixes([FailureReport.t()], module(), options()) :: [
          {FailureReport.t(), verification_result()}
        ]
  def verify_fixes(failures, model, opts \\ []) do
    Enum.map(failures, fn failure ->
      {failure, verify_fix(failure, model, opts)}
    end)
  end

  @doc """
  Quick check if a single seed still fails.
  """
  @spec still_fails?(integer(), module(), module(), map()) :: boolean()
  def still_fails?(seed, model, adapter, adapter_config \\ %{}) do
    case run_seed(seed, model, adapter, adapter_config) do
      :ok -> false
      {:error, _} -> true
    end
  end

  @doc """
  Runs verification against a cluster of similar failures.

  If the fix addresses the root cause, all similar failures should pass.
  """
  @spec verify_cluster(Patterns.cluster(), module(), options()) :: %{
          cluster_id: String.t(),
          total: non_neg_integer(),
          fixed: non_neg_integer(),
          remaining: non_neg_integer(),
          status: :fully_fixed | :partially_fixed | :not_fixed,
          remaining_failures: [Fingerprint.t()]
        }
  def verify_cluster(cluster, _model, _opts) do
    # Note: Full cluster verification requires seeds associated with fingerprints.
    # This is a placeholder that reports cluster status without re-running.
    # In production usage, cluster fingerprints would include seed references.
    results =
      Enum.map(cluster.fingerprints, fn fp ->
        {fp, :unknown}
      end)

    # Count results
    fixed = Enum.count(results, fn {_, status} -> status == :ok end)
    remaining = Enum.count(results, fn {_, status} -> status != :ok end)

    status =
      cond do
        remaining == 0 -> :fully_fixed
        fixed > 0 -> :partially_fixed
        true -> :not_fixed
      end

    remaining_fps =
      results
      |> Enum.filter(fn {_, status} -> status != :ok end)
      |> Enum.map(fn {fp, _} -> fp end)

    %{
      cluster_id: cluster.id,
      total: cluster.size,
      fixed: fixed,
      remaining: remaining,
      status: status,
      remaining_failures: remaining_fps
    }
  end

  @doc """
  Generates a verification report for display.
  """
  @spec format_result(verification_result()) :: String.t()
  def format_result(result) do
    status_icon =
      case result.status do
        :verified -> "✓"
        :still_failing -> "✗"
        :partially_fixed -> "⚠"
        :flaky -> "?"
      end

    """
    #{status_icon} Verification Result: #{result.status}
    ─────────────────────────────────────────────
    Original seed: #{result.original_seed}
    Original passes: #{result.original_passes}

    Variations tested: #{result.variations_run}
    Passed: #{result.variations_passed}
    Failed: #{result.variations_failed}

    Confidence: #{Float.round(result.confidence * 100, 1)}%

    #{result.summary}
    """
    |> String.trim()
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp run_seed(seed, model, adapter, adapter_config) do
    result =
      PropertyDamage.run(
        model: model,
        adapter: adapter,
        adapter_config: adapter_config,
        seed: seed,
        max_runs: 1,
        quiet: true
      )

    case result do
      {:ok, _stats} -> :ok
      {:error, %FailureReport{} = report} -> {:error, report}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  rescue
    e ->
      {:error, %{exception: e}}
  end

  defp generate_variations(original_seed, count, range) do
    # Generate seeds around the original
    half_range = div(range, 2)

    nearby =
      for offset <- -half_range..half_range,
          offset != 0,
          seed = original_seed + offset,
          seed > 0 do
        seed
      end

    # Also include some random variations
    random_count = div(count, 2)

    random =
      for _ <- 1..random_count do
        :rand.uniform(1_000_000_000)
      end

    (nearby ++ random)
    |> Enum.uniq()
    |> Enum.take(count)
  end

  defp build_result(
         original_seed,
         original_result,
         passed_count,
         failed_seeds,
         similar_failures,
         total_variations
       ) do
    original_passes = original_result == :ok
    failed_count = length(failed_seeds)

    status =
      cond do
        not original_passes ->
          :still_failing

        failed_count == 0 ->
          :verified

        failed_count <= div(total_variations, 4) ->
          # Less than 25% failure rate
          :flaky

        true ->
          :partially_fixed
      end

    confidence = calculate_confidence(original_passes, passed_count, total_variations)

    summary = generate_summary(status, original_passes, passed_count, failed_count)

    %{
      status: status,
      original_seed: original_seed,
      original_passes: original_passes,
      variations_run: total_variations,
      variations_passed: passed_count,
      variations_failed: failed_count,
      failed_variations: failed_seeds,
      similar_failures: similar_failures,
      confidence: confidence,
      summary: summary
    }
  end

  defp calculate_confidence(original_passes, passed_count, total_variations) do
    if total_variations == 0 do
      if original_passes, do: 0.5, else: 0.0
    else
      pass_rate = passed_count / total_variations
      base = if original_passes, do: 0.3, else: 0.0
      base + 0.7 * pass_rate
    end
  end

  defp generate_summary(status, original_passes, passed_count, failed_count) do
    case status do
      :verified ->
        "Fix verified! Original seed and all #{passed_count} variations pass."

      :still_failing ->
        "Fix NOT verified. Original failure still reproduces."

      :flaky ->
        "Fix may be incomplete. Original passes but #{failed_count} variations still fail. " <>
          "This could indicate a timing issue or incomplete fix."

      :partially_fixed ->
        "Fix is partial. Original #{if original_passes, do: "passes", else: "fails"} " <>
          "but #{failed_count} of #{passed_count + failed_count} variations fail."
    end
  end
end
