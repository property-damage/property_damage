defmodule PropertyDamage.FailureIntelligence.Patterns do
  @moduledoc """
  Pattern detection and clustering for failures.

  Identifies groups of similar failures and extracts common patterns
  that can help understand systemic issues.
  """

  alias PropertyDamage.FailureIntelligence.{Fingerprint, Similarity}
  alias PropertyDamage.FailureReport

  @type cluster :: %{
          id: String.t(),
          fingerprints: [Fingerprint.t()],
          representative: Fingerprint.t(),
          size: non_neg_integer(),
          pattern: pattern()
        }

  @type pattern :: %{
          failure_type: atom(),
          check_name: atom() | nil,
          command_types: [atom()],
          event_types: [atom()],
          error_category: atom(),
          common_fields: [atom()],
          description: String.t()
        }

  @type analysis :: %{
          clusters: [cluster()],
          singleton_count: non_neg_integer(),
          total_failures: non_neg_integer(),
          most_common_pattern: pattern() | nil,
          pattern_summary: String.t()
        }

  @default_threshold 0.70
  @min_cluster_size 2

  @doc """
  Clusters failures by similarity.

  Uses a simple agglomerative clustering approach with the given threshold.
  """
  @spec cluster_failures([FailureReport.t()], keyword()) :: [cluster()]
  def cluster_failures(failures, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    # Convert failures to fingerprints
    fingerprints = Enum.map(failures, &Fingerprint.from_failure_report/1)

    cluster_fingerprints(fingerprints, threshold)
  end

  @doc """
  Clusters fingerprints by similarity.
  """
  @spec cluster_fingerprints([Fingerprint.t()], float()) :: [cluster()]
  def cluster_fingerprints(fingerprints, threshold \\ @default_threshold) do
    # Start with each fingerprint in its own cluster
    initial_clusters =
      fingerprints
      |> Enum.with_index()
      |> Enum.map(fn {fp, i} ->
        %{
          id: generate_cluster_id(i),
          fingerprints: [fp],
          representative: fp,
          size: 1
        }
      end)

    # Merge similar clusters
    merged = merge_clusters(initial_clusters, threshold)

    # Extract patterns and filter to significant clusters
    merged
    |> Enum.map(&add_pattern/1)
    |> Enum.sort_by(& &1.size, :desc)
  end

  @doc """
  Analyzes a set of failures to identify patterns.

  Returns clustering information and pattern summaries.
  """
  @spec analyze([FailureReport.t()], keyword()) :: analysis()
  def analyze(failures, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    min_size = Keyword.get(opts, :min_cluster_size, @min_cluster_size)

    clusters = cluster_failures(failures, threshold: threshold)

    significant_clusters = Enum.filter(clusters, &(&1.size >= min_size))
    singletons = Enum.filter(clusters, &(&1.size < min_size))

    most_common =
      if significant_clusters != [] do
        hd(significant_clusters).pattern
      else
        nil
      end

    %{
      clusters: significant_clusters,
      singleton_count: length(singletons),
      total_failures: length(failures),
      most_common_pattern: most_common,
      pattern_summary: generate_summary(significant_clusters, singletons, failures)
    }
  end

  @doc """
  Detects if a new failure matches an existing pattern.

  Returns the matching cluster if found, nil otherwise.
  """
  @spec match_pattern(FailureReport.t(), [cluster()], keyword()) :: cluster() | nil
  def match_pattern(failure, clusters, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    fp = Fingerprint.from_failure_report(failure)

    Enum.find(clusters, fn cluster ->
      Similarity.score(fp, cluster.representative) >= threshold
    end)
  end

  @doc """
  Finds the best matching cluster for a failure.

  Returns `{cluster, score}` or nil if no clusters are provided.
  """
  @spec find_best_match(FailureReport.t(), [cluster()]) :: {cluster(), float()} | nil
  def find_best_match(_failure, []), do: nil

  def find_best_match(failure, clusters) do
    fp = Fingerprint.from_failure_report(failure)

    clusters
    |> Enum.map(fn c -> {c, Similarity.score(fp, c.representative)} end)
    |> Enum.max_by(fn {_c, score} -> score end)
  end

  @doc """
  Extracts common traits from a cluster of fingerprints.
  """
  @spec extract_common_traits([Fingerprint.t()]) :: map()
  def extract_common_traits([]), do: %{}

  def extract_common_traits(fingerprints) do
    # Find values that are the same across all fingerprints
    %{
      failure_type: common_value(fingerprints, :failure_type),
      check_name: common_value(fingerprints, :check_name),
      command_type: common_value(fingerprints, :command_type),
      error_category: common_value(fingerprints, :error_category),
      common_event_types: common_list(fingerprints, :event_types),
      common_state_keys: common_list(fingerprints, :state_keys)
    }
  end

  # ============================================================================
  # Clustering Implementation
  # ============================================================================

  defp merge_clusters(clusters, threshold) do
    case find_mergeable_pair(clusters, threshold) do
      nil ->
        clusters

      {i, j} ->
        # Merge clusters at indices i and j
        c1 = Enum.at(clusters, i)
        c2 = Enum.at(clusters, j)

        merged = %{
          id: c1.id,
          fingerprints: c1.fingerprints ++ c2.fingerprints,
          representative: select_representative(c1.fingerprints ++ c2.fingerprints),
          size: c1.size + c2.size
        }

        # Remove old clusters and add merged one
        clusters
        |> List.delete_at(max(i, j))
        |> List.delete_at(min(i, j))
        |> List.insert_at(0, merged)
        |> merge_clusters(threshold)
    end
  end

  defp find_mergeable_pair(clusters, threshold) do
    indexed = Enum.with_index(clusters)

    pairs =
      for {c1, i} <- indexed,
          {c2, j} <- indexed,
          i < j do
        score = Similarity.score(c1.representative, c2.representative)
        {i, j, score}
      end

    case Enum.filter(pairs, fn {_, _, score} -> score >= threshold end) do
      [] ->
        nil

      mergeable ->
        {i, j, _} = Enum.max_by(mergeable, fn {_, _, score} -> score end)
        {i, j}
    end
  end

  defp select_representative(fingerprints) do
    # Select the fingerprint with highest average similarity to others
    # (the most "central" fingerprint)
    if length(fingerprints) == 1 do
      hd(fingerprints)
    else
      fingerprints
      |> Enum.map(fn fp ->
        avg_sim =
          fingerprints
          |> Enum.reject(&(&1 == fp))
          |> Enum.map(&Similarity.score(fp, &1))
          |> case do
            [] -> 0.0
            scores -> Enum.sum(scores) / length(scores)
          end

        {fp, avg_sim}
      end)
      |> Enum.max_by(fn {_fp, avg} -> avg end)
      |> elem(0)
    end
  end

  defp add_pattern(cluster) do
    pattern = extract_pattern(cluster.fingerprints)
    Map.put(cluster, :pattern, pattern)
  end

  defp extract_pattern(fingerprints) do
    traits = extract_common_traits(fingerprints)

    # Get all command types seen
    command_types =
      fingerprints
      |> Enum.flat_map(&List.wrap(&1.command_type))
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    # Get all event types seen
    event_types =
      fingerprints
      |> Enum.flat_map(& &1.event_types)
      |> Enum.uniq()

    %{
      failure_type: traits.failure_type,
      check_name: traits.check_name,
      command_types: command_types,
      event_types: event_types,
      error_category: traits.error_category,
      common_fields: traits.common_state_keys || [],
      description: generate_pattern_description(traits, command_types, length(fingerprints))
    }
  end

  defp generate_pattern_description(traits, command_types, count) do
    # Keyed on the real `PropertyDamage.Failure.kind/1` vocabulary that
    # fingerprints actually carry (via `FailureReport.failure_type/1`); the old
    # `:check_failed`/`:invariant_violated`/... atoms never matched, so every
    # cluster degraded to the generic "Failure".
    type_desc =
      case traits.failure_type do
        :assertion_failed -> "Check failure"
        :projection_violation -> "Invariant violation"
        :idempotency_violation -> "Idempotency violation"
        :poll_timeout -> "Poll timeout"
        :poll_error -> "Poll predicate error"
        :settle_timeout -> "Settle timeout"
        :adapter_error -> "Adapter error"
        :nemesis_error -> "Fault injection error"
        :linearization -> "Linearization failure"
        :stutter_execution_failed -> "Stutter execution failure"
        :resource_poller_error -> "Resource poller error"
        :retry_from_sync_command -> "Sync command returned retry"
        :malformed_adapter_return -> "Malformed adapter return"
        :placeholder_resolution -> "Placeholder resolution error"
        _ -> "Failure"
      end

    check_desc =
      if traits.check_name do
        " in #{inspect(traits.check_name)}"
      else
        ""
      end

    cmd_desc =
      case command_types do
        [] -> ""
        [cmd] -> " during #{format_module(cmd)}"
        cmds -> " during #{length(cmds)} command types"
      end

    "#{type_desc}#{check_desc}#{cmd_desc} (#{count} occurrences)"
  end

  defp format_module(nil), do: "unknown"

  defp format_module(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  defp format_module(_), do: "unknown"

  # ============================================================================
  # Common Value Extraction
  # ============================================================================

  defp common_value(fingerprints, key) do
    values =
      fingerprints
      |> Enum.map(&Map.get(&1, key))
      |> Enum.uniq()

    case values do
      [single] -> single
      _ -> nil
    end
  end

  defp common_list(fingerprints, key) do
    fingerprints
    |> Enum.map(&Map.get(&1, key, []))
    |> Enum.map(&MapSet.new/1)
    |> Enum.reduce(&MapSet.intersection/2)
    |> MapSet.to_list()
  end

  # ============================================================================
  # Summary Generation
  # ============================================================================

  defp generate_summary(clusters, singletons, failures) do
    total = length(failures)

    if total == 0 do
      "No failures to analyze"
    else
      clustered = clusters |> Enum.map(& &1.size) |> Enum.sum()
      singleton_count = length(singletons)

      pattern_list =
        clusters
        |> Enum.take(3)
        |> Enum.map_join("\n", fn c -> "  - #{c.pattern.description}" end)

      """
      Analyzed #{total} failures:
      - #{length(clusters)} distinct patterns (#{clustered} failures)
      - #{singleton_count} unique failures (no pattern match)
      #{if pattern_list != "", do: "\nTop patterns:\n#{pattern_list}", else: ""}
      """
      |> String.trim()
    end
  end

  defp generate_cluster_id(index) do
    "cluster_#{index}_#{:erlang.unique_integer([:positive])}"
  end
end
