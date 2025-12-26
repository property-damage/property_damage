defmodule PropertyDamage.FailureIntelligence.Similarity do
  @moduledoc """
  Computes similarity scores between failure fingerprints.

  Uses multiple metrics to determine how similar two failures are,
  enabling pattern detection and clustering.
  """

  alias PropertyDamage.FailureIntelligence.Fingerprint

  @type score :: float()
  @type comparison :: %{
          score: score(),
          breakdown: %{
            failure_type: score(),
            check_name: score(),
            command_type: score(),
            command_shape: score(),
            event_types: score(),
            sequence_shape: score(),
            error_category: score(),
            error_pattern: score()
          },
          is_similar: boolean()
        }

  # Weights for different similarity components
  @weights %{
    failure_type: 0.20,
    check_name: 0.15,
    command_type: 0.15,
    command_shape: 0.10,
    event_types: 0.10,
    sequence_shape: 0.10,
    error_category: 0.10,
    error_pattern: 0.10
  }

  @similarity_threshold 0.70

  @doc """
  Computes the similarity score between two fingerprints.

  Returns a score between 0.0 (completely different) and 1.0 (identical).
  """
  @spec score(Fingerprint.t(), Fingerprint.t()) :: score()
  def score(%Fingerprint{} = fp1, %Fingerprint{} = fp2) do
    compare(fp1, fp2).score
  end

  @doc """
  Performs a detailed comparison between two fingerprints.

  Returns the overall score, per-component breakdown, and similarity determination.
  """
  @spec compare(Fingerprint.t(), Fingerprint.t()) :: comparison()
  def compare(%Fingerprint{} = fp1, %Fingerprint{} = fp2) do
    breakdown = %{
      failure_type: exact_match_score(fp1.failure_type, fp2.failure_type),
      check_name: exact_match_score(fp1.check_name, fp2.check_name),
      command_type: exact_match_score(fp1.command_type, fp2.command_type),
      command_shape: map_similarity(fp1.command_shape, fp2.command_shape),
      event_types: list_similarity(fp1.event_types, fp2.event_types),
      sequence_shape: sequence_similarity(fp1.sequence_shape, fp2.sequence_shape),
      error_category: exact_match_score(fp1.error_category, fp2.error_category),
      error_pattern: string_similarity(fp1.error_pattern, fp2.error_pattern)
    }

    weighted_score = calculate_weighted_score(breakdown)

    %{
      score: weighted_score,
      breakdown: breakdown,
      is_similar: weighted_score >= @similarity_threshold
    }
  end

  @doc """
  Checks if two fingerprints are similar based on the threshold.
  """
  @spec similar?(Fingerprint.t(), Fingerprint.t()) :: boolean()
  def similar?(%Fingerprint{} = fp1, %Fingerprint{} = fp2) do
    score(fp1, fp2) >= @similarity_threshold
  end

  @doc """
  Checks if two fingerprints are similar using a custom threshold.
  """
  @spec similar?(Fingerprint.t(), Fingerprint.t(), float()) :: boolean()
  def similar?(%Fingerprint{} = fp1, %Fingerprint{} = fp2, threshold) do
    score(fp1, fp2) >= threshold
  end

  @doc """
  Finds the most similar fingerprint from a list.

  Returns `{fingerprint, score}` or `nil` if no fingerprints are provided.
  """
  @spec find_most_similar(Fingerprint.t(), [Fingerprint.t()]) ::
          {Fingerprint.t(), score()} | nil
  def find_most_similar(_target, []), do: nil

  def find_most_similar(%Fingerprint{} = target, fingerprints) do
    fingerprints
    |> Enum.map(fn fp -> {fp, score(target, fp)} end)
    |> Enum.max_by(fn {_fp, s} -> s end)
  end

  @doc """
  Finds all fingerprints similar to the target.

  Returns a list of `{fingerprint, score}` pairs, sorted by score descending.
  """
  @spec find_similar(Fingerprint.t(), [Fingerprint.t()], keyword()) ::
          [{Fingerprint.t(), score()}]
  def find_similar(%Fingerprint{} = target, fingerprints, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @similarity_threshold)
    limit = Keyword.get(opts, :limit, nil)

    results =
      fingerprints
      |> Enum.map(fn fp -> {fp, score(target, fp)} end)
      |> Enum.filter(fn {_fp, s} -> s >= threshold end)
      |> Enum.sort_by(fn {_fp, s} -> s end, :desc)

    if limit, do: Enum.take(results, limit), else: results
  end

  @doc """
  Computes a similarity matrix for a list of fingerprints.

  Returns a map where keys are `{index1, index2}` and values are scores.
  Only computes upper triangle (i < j) since similarity is symmetric.
  """
  @spec similarity_matrix([Fingerprint.t()]) :: %{
          {non_neg_integer(), non_neg_integer()} => score()
        }
  def similarity_matrix(fingerprints) do
    indexed = Enum.with_index(fingerprints)

    for {fp1, i} <- indexed,
        {fp2, j} <- indexed,
        i < j,
        into: %{} do
      {{i, j}, score(fp1, fp2)}
    end
  end

  # ============================================================================
  # Similarity Metrics
  # ============================================================================

  defp exact_match_score(nil, nil), do: 1.0
  defp exact_match_score(nil, _), do: 0.0
  defp exact_match_score(_, nil), do: 0.0
  defp exact_match_score(a, a), do: 1.0
  defp exact_match_score(_, _), do: 0.0

  defp map_similarity(nil, nil), do: 1.0
  defp map_similarity(nil, _), do: 0.0
  defp map_similarity(_, nil), do: 0.0

  defp map_similarity(map1, map2) when map_size(map1) == 0 and map_size(map2) == 0 do
    1.0
  end

  defp map_similarity(map1, map2) do
    keys1 = MapSet.new(Map.keys(map1))
    keys2 = MapSet.new(Map.keys(map2))

    # Jaccard similarity of keys
    key_intersection = MapSet.intersection(keys1, keys2) |> MapSet.size()
    key_union = MapSet.union(keys1, keys2) |> MapSet.size()

    if key_union == 0 do
      1.0
    else
      key_similarity = key_intersection / key_union

      # Value type similarity for shared keys
      shared_keys = MapSet.intersection(keys1, keys2)

      value_similarity =
        if MapSet.size(shared_keys) == 0 do
          0.0
        else
          matching =
            shared_keys
            |> Enum.count(fn k -> Map.get(map1, k) == Map.get(map2, k) end)

          matching / MapSet.size(shared_keys)
        end

      # Weight key similarity more heavily
      0.6 * key_similarity + 0.4 * value_similarity
    end
  end

  defp list_similarity(nil, nil), do: 1.0
  defp list_similarity(nil, _), do: 0.0
  defp list_similarity(_, nil), do: 0.0
  defp list_similarity([], []), do: 1.0

  defp list_similarity(list1, list2) do
    set1 = MapSet.new(list1)
    set2 = MapSet.new(list2)

    intersection = MapSet.intersection(set1, set2) |> MapSet.size()
    union = MapSet.union(set1, set2) |> MapSet.size()

    if union == 0, do: 1.0, else: intersection / union
  end

  defp sequence_similarity(nil, nil), do: 1.0
  defp sequence_similarity(nil, _), do: 0.0
  defp sequence_similarity(_, nil), do: 0.0
  defp sequence_similarity([], []), do: 1.0

  defp sequence_similarity(seq1, seq2) do
    # Use a combination of set similarity and sequence alignment
    set_sim = list_similarity(seq1, seq2)

    # Length penalty for very different lengths
    len1 = length(seq1)
    len2 = length(seq2)

    len_sim =
      if len1 == 0 and len2 == 0 do
        1.0
      else
        min(len1, len2) / max(len1, len2)
      end

    # Prefix similarity (important for command sequences)
    prefix_sim = prefix_similarity(seq1, seq2)

    0.4 * set_sim + 0.3 * len_sim + 0.3 * prefix_sim
  end

  defp prefix_similarity([], []), do: 1.0
  defp prefix_similarity([], _), do: 0.0
  defp prefix_similarity(_, []), do: 0.0

  defp prefix_similarity(seq1, seq2) do
    max_len = max(length(seq1), length(seq2))

    common_prefix_len =
      Enum.zip(seq1, seq2)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

    common_prefix_len / max_len
  end

  defp string_similarity(nil, nil), do: 1.0
  defp string_similarity(nil, _), do: 0.0
  defp string_similarity(_, nil), do: 0.0
  defp string_similarity(s, s), do: 1.0

  defp string_similarity(s1, s2) do
    # Use normalized edit distance
    len1 = String.length(s1)
    len2 = String.length(s2)
    max_len = max(len1, len2)

    if max_len == 0 do
      1.0
    else
      distance = levenshtein_distance(s1, s2)
      max(0.0, 1.0 - distance / max_len)
    end
  end

  # Simple Levenshtein distance implementation
  defp levenshtein_distance(s1, s2) do
    s1_chars = String.graphemes(s1)
    s2_chars = String.graphemes(s2)

    len2 = length(s2_chars)

    # Use dynamic programming with space optimization
    # Only keep two rows at a time
    initial_row = Enum.to_list(0..len2)

    {final_row, _} =
      Enum.reduce(Enum.with_index(s1_chars, 1), {initial_row, initial_row}, fn {c1, i},
                                                                               {prev_row, _} ->
        current_row =
          Enum.reduce(Enum.with_index(s2_chars, 1), [i], fn {c2, j}, acc ->
            prev_val = Enum.at(prev_row, j)
            left_val = List.last(acc)
            diag_val = Enum.at(prev_row, j - 1)

            cost = if c1 == c2, do: 0, else: 1

            val =
              min(
                min(left_val + 1, prev_val + 1),
                diag_val + cost
              )

            acc ++ [val]
          end)

        {current_row, prev_row}
      end)

    List.last(final_row)
  end

  defp calculate_weighted_score(breakdown) do
    Enum.reduce(@weights, 0.0, fn {key, weight}, acc ->
      component_score = Map.get(breakdown, key, 0.0)
      acc + weight * component_score
    end)
  end
end
