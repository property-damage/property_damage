defmodule PropertyDamage.FailureIntelligence.Exploration do
  @moduledoc """
  Samples plans drawn from seeds near the seed of a failure report.

  Exploration runs each neighbouring seed once and lists the seeds that fail.
  It gives no verification verdict: a passing seed says nothing about the
  shrunk sequence of the report. Use
  `PropertyDamage.FailureIntelligence.Verification.verify_fix/3` to check a
  fix.
  """

  alias PropertyDamage.{FailureReport, Options, Target}

  @type result :: %{
          original_seed: integer(),
          seeds_run: non_neg_integer(),
          passed: non_neg_integer(),
          failures: [%{seed: integer(), report: FailureReport.t()}]
        }

  @type options :: [
          targets: [module() | {module(), keyword()}],
          max_seeds: non_neg_integer(),
          seed_range: integer()
        ]

  @default_max_seeds 10
  @default_seed_range 1000

  @doc """
  Runs plans drawn from seeds near `report.seed` and returns the ones that
  fail.

  The seeds are a sample, not the plans of the original run, and the result
  holds no verdict.

  ## Options

  - `:targets` - A list with exactly one entry (required): the adapter to run
    against, as a module or `{AdapterModule, config: map, ...}`; see
    `PropertyDamage.Target`
  - `:max_seeds` - Maximum number of seeds to run (default: 10)
  - `:seed_range` - Width of the range of seeds around the original seed
    (default: 1000)

  ## Return value

  A map with `:original_seed`, `:seeds_run`, `:passed` and `:failures`, a list
  of `%{seed: seed, report: report}` for each seed whose run fails.
  """
  @spec explore_neighbouring_seeds(FailureReport.t(), module(), options()) :: result()
  def explore_neighbouring_seeds(%FailureReport{} = report, model, opts \\ []) do
    target = Options.required_target!(opts)
    max_seeds = Keyword.get(opts, :max_seeds, @default_max_seeds)
    seed_range = Keyword.get(opts, :seed_range, @default_seed_range)

    seeds = neighbouring_seeds(report.seed, max_seeds, seed_range)
    outcomes = Enum.map(seeds, fn seed -> {seed, run_seed(seed, model, target)} end)

    failures =
      for {seed, {:error, %FailureReport{} = failed}} <- outcomes,
          do: %{seed: seed, report: failed}

    %{
      original_seed: report.seed,
      seeds_run: length(seeds),
      passed: Enum.count(outcomes, &match?({_seed, {:ok, _stats}}, &1)),
      failures: failures
    }
  end

  defp run_seed(seed, model, target) do
    PropertyDamage.run(
      model: model,
      targets: [Target.to_entry(target)],
      seed: seed,
      max_runs: 1,
      replay_dir: false,
      verbose: false
    )
  end

  defp neighbouring_seeds(original_seed, count, range) do
    half_range = div(range, 2)

    nearby =
      for offset <- -half_range..half_range//1,
          offset != 0,
          seed = original_seed + offset,
          seed > 0 do
        seed
      end

    random_count = div(count, 2)
    random = for _ <- 1..random_count//1, do: :rand.uniform(1_000_000_000)

    (nearby ++ random)
    |> Enum.uniq()
    |> Enum.take(count)
  end
end
