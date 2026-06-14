defmodule PropertyDamage.Flakiness do
  @moduledoc """
  Detect non-deterministic behavior in the system under test.

  Flaky tests are tests that sometimes pass and sometimes fail with the same
  input. This is often caused by:

  - Race conditions in the SUT
  - External dependencies (time, network, etc.)
  - Uninitialized state between runs
  - Non-deterministic SUT behavior

  ## Usage

      # Check if a specific seed is flaky
      result = PropertyDamage.check_determinism(
        model: M,
        adapter: A,
        seed: 512902757,
        runs: 10
      )

      case result do
        {:ok, :deterministic} ->
          IO.puts("Seed is deterministic")

        {:ok, :flaky, stats} ->
          IO.puts("Seed is FLAKY: passed \#{stats.passes}/\#{stats.runs} times")

        {:error, reason} ->
          IO.puts("Check failed: \#{inspect(reason)}")
      end

  ## Batch Checking

      # Check multiple seeds at once
      results = PropertyDamage.check_determinism_batch(
        model: M,
        adapter: A,
        seeds: [123, 456, 789],
        runs_per_seed: 5
      )

  ## Understanding Results

  The checker reports:
  - **Deterministic**: Same result every run
  - **Flaky**: Different results across runs
  - **Variance**: What varies (pass/fail, failure type, shrunk size)
  """

  alias PropertyDamage.Sequence

  @type result ::
          {:ok, :deterministic}
          | {:ok, :flaky, flaky_stats()}
          | {:error, term()}

  @type flaky_stats :: %{
          runs: non_neg_integer(),
          passes: non_neg_integer(),
          failures: non_neg_integer(),
          failure_types: %{atom() => non_neg_integer()},
          shrunk_sizes: [non_neg_integer()],
          variance_type: :pass_fail | :failure_type | :shrunk_size | :multiple
        }

  @type check_opts :: [
          runs: non_neg_integer(),
          adapter_config: map(),
          max_commands: non_neg_integer(),
          verbose: boolean()
        ]

  @doc """
  Check if a seed produces deterministic results.

  Runs the same seed multiple times and compares outcomes.

  ## Options

  - `:runs` - Number of times to run (default: 5)
  - `:adapter_config` - Adapter configuration
  - `:max_commands` - Maximum commands per run (default: 50)
  - `:verbose` - Print progress (default: false)

  ## Returns

  - `{:ok, :deterministic}` - Same result every time
  - `{:ok, :flaky, stats}` - Different results, with statistics
  - `{:error, reason}` - Check failed
  """
  @spec check(module(), module(), integer(), check_opts()) :: result()
  def check(model, adapter, seed, opts \\ []) do
    runs = Keyword.get(opts, :runs, 5)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    max_commands = Keyword.get(opts, :max_commands, 50)
    verbose = Keyword.get(opts, :verbose, false)

    if verbose, do: IO.puts("Checking seed #{seed} with #{runs} runs...")

    results =
      for i <- 1..runs do
        if verbose, do: IO.write("  Run #{i}/#{runs}... ")

        result =
          PropertyDamage.run(
            model: model,
            adapter: adapter,
            seed: seed,
            max_commands: max_commands,
            max_runs: 1,
            adapter_config: adapter_config
          )

        if verbose do
          case result do
            {:ok, _} -> IO.puts("PASS")
            {:error, f} -> IO.puts("FAIL (#{f.failure_type})")
          end
        end

        result
      end

    analyze_results(results, runs)
  end

  @doc """
  Check multiple seeds for flakiness.

  ## Options

  Same as `check/4`, plus:
  - `:runs_per_seed` - Runs per seed (default: 5)
  - `:parallel` - Run seeds in parallel (default: false)

  ## Returns

  Map from seed to result.
  """
  @spec check_batch(module(), module(), [integer()], keyword()) :: %{integer() => result()}
  def check_batch(model, adapter, seeds, opts \\ []) do
    runs_per_seed = Keyword.get(opts, :runs_per_seed, 5)
    check_opts = Keyword.put(opts, :runs, runs_per_seed)

    seeds
    |> Enum.map(fn seed ->
      {seed, check(model, adapter, seed, check_opts)}
    end)
    |> Map.new()
  end

  @doc """
  Run random seeds and identify flaky ones.

  This is useful for discovering non-determinism in your SUT without
  knowing specific problematic seeds.

  ## Options

  - `:num_seeds` - Number of random seeds to test (default: 10)
  - `:runs_per_seed` - Runs per seed (default: 3)
  - Other options passed to `check/4`

  ## Returns

  List of `{seed, flaky_stats}` for seeds that are flaky.
  """
  @spec discover_flaky(module(), module(), keyword()) :: [{integer(), flaky_stats()}]
  def discover_flaky(model, adapter, opts \\ []) do
    num_seeds = Keyword.get(opts, :num_seeds, 10)
    runs_per_seed = Keyword.get(opts, :runs_per_seed, 3)
    verbose = Keyword.get(opts, :verbose, false)

    if verbose, do: IO.puts("Testing #{num_seeds} random seeds...")

    seeds = for _ <- 1..num_seeds, do: :rand.uniform(1_000_000_000)

    check_opts =
      opts
      |> Keyword.put(:runs, runs_per_seed)
      |> Keyword.put(:verbose, false)

    seeds
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {seed, i} ->
      if verbose, do: IO.write("Seed #{i}/#{num_seeds} (#{seed})... ")

      case check(model, adapter, seed, check_opts) do
        {:ok, :flaky, stats} ->
          if verbose, do: IO.puts("FLAKY")
          [{seed, stats}]

        {:ok, :deterministic} ->
          if verbose, do: IO.puts("ok")
          []
      end
    end)
  end

  @doc """
  Format flakiness check results for display.
  """
  @spec format_result(result()) :: String.t()
  def format_result({:ok, :deterministic}) do
    "DETERMINISTIC - Same result every run"
  end

  def format_result({:ok, :flaky, stats}) do
    """
    FLAKY - Results vary across runs

    Statistics:
      Total runs: #{stats.runs}
      Passes: #{stats.passes}
      Failures: #{stats.failures}
      Pass rate: #{Float.round(stats.passes / stats.runs * 100, 1)}%

    Variance type: #{format_variance_type(stats.variance_type)}

    Failure types: #{format_failure_types(stats.failure_types)}
    Shrunk sizes: #{inspect(stats.shrunk_sizes)}
    """
  end

  def format_result({:error, reason}) do
    "ERROR: #{inspect(reason)}"
  end

  @doc """
  Format batch results for display.
  """
  @spec format_batch(%{integer() => result()}) :: String.t()
  def format_batch(results) do
    {deterministic, flaky} =
      Enum.split_with(results, fn {_seed, result} ->
        match?({:ok, :deterministic}, result)
      end)

    flaky_details =
      flaky
      |> Enum.map_join("\n", fn {seed, {:ok, :flaky, stats}} ->
        "  Seed #{seed}: #{stats.passes}/#{stats.runs} passes (#{format_variance_type(stats.variance_type)})"
      end)

    """
    Flakiness Check Results
    =======================
    Deterministic: #{length(deterministic)}
    Flaky: #{length(flaky)}

    #{if flaky_details != "", do: "Flaky seeds:\n#{flaky_details}", else: "No flaky seeds found!"}
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp analyze_results(results, total_runs) do
    passes = Enum.count(results, &match?({:ok, _}, &1))
    failures = total_runs - passes

    if passes == total_runs or failures == total_runs do
      # All same outcome
      if all_identical?(results) do
        {:ok, :deterministic}
      else
        # Same pass/fail but different details
        stats = build_stats(results, total_runs, passes, failures)
        {:ok, :flaky, stats}
      end
    else
      # Mixed pass/fail
      stats = build_stats(results, total_runs, passes, failures)
      {:ok, :flaky, stats}
    end
  end

  defp all_identical?(results) do
    case results do
      [] ->
        true

      [first | rest] ->
        Enum.all?(rest, &results_equal?(first, &1))
    end
  end

  defp results_equal?({:ok, _}, {:ok, _}), do: true

  defp results_equal?({:error, f1}, {:error, f2}) do
    # Compare key aspects
    f1.failure_type == f2.failure_type and
      f1.check_name == f2.check_name and
      length(Sequence.to_list(f1.shrunk_sequence)) ==
        length(Sequence.to_list(f2.shrunk_sequence))
  end

  defp results_equal?(_, _), do: false

  defp build_stats(results, total_runs, passes, failures) do
    failure_types =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, f} -> f.failure_type end)
      |> Enum.frequencies()

    shrunk_sizes =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, f} -> length(Sequence.to_list(f.shrunk_sequence)) end)

    variance_type = determine_variance_type(passes, failures, failure_types, shrunk_sizes)

    %{
      runs: total_runs,
      passes: passes,
      failures: failures,
      failure_types: failure_types,
      shrunk_sizes: shrunk_sizes,
      variance_type: variance_type
    }
  end

  defp determine_variance_type(passes, failures, failure_types, shrunk_sizes) do
    cond do
      passes > 0 and failures > 0 ->
        :pass_fail

      map_size(failure_types) > 1 ->
        :failure_type

      length(Enum.uniq(shrunk_sizes)) > 1 ->
        :shrunk_size

      true ->
        :multiple
    end
  end

  defp format_variance_type(:pass_fail), do: "Pass/Fail variance (most severe)"
  defp format_variance_type(:failure_type), do: "Different failure types"
  defp format_variance_type(:shrunk_size), do: "Different shrunk sizes"
  defp format_variance_type(:multiple), do: "Multiple variance types"

  defp format_failure_types(types) when map_size(types) == 0, do: "(none)"

  defp format_failure_types(types) do
    types
    |> Enum.map_join(", ", fn {type, count} -> "#{type}: #{count}" end)
  end
end
