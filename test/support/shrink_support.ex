defmodule PropertyDamage.Test.ShrinkSupport do
  @moduledoc false
  # Shrinks against a real system: builds the oracle with
  # `PropertyDamage.Runner.shrink_oracle/2` from the run options a test passes
  # and calls `PropertyDamage.Shrinker.shrink/2` with the rest.

  alias PropertyDamage.{Failure, Runner, Shrinker}

  # The options that say how a candidate runs: they build the oracle.
  @run_options [:concurrency, :compare, :check_mode, :keep_attempts, :stutter_config, :run_nonce]

  @doc """
  `Shrinker.shrink/2` with an oracle built from `opts`. `opts` takes the
  shrinker's options plus how every candidate runs: `:concurrency`,
  `:compare`, `:check_mode`, `:keep_attempts`, `:stutter_config` and
  `:run_nonce`, each defaulting as on `PropertyDamage.Runner.Context`.
  """
  def shrink(sequence, opts) do
    {run_opts, shrink_opts} = Keyword.split(opts, @run_options)

    context =
      struct!(
        %Runner.Context{
          model: Keyword.fetch!(opts, :model),
          targets: Keyword.fetch!(opts, :targets),
          seed: Keyword.get(opts, :rng_seed) || 0,
          run_number: 0
        },
        run_opts
      )

    signature =
      case Keyword.get(opts, :failure_reason) do
        nil -> nil
        reason -> Failure.signature(reason, Keyword.get(opts, :variant_index, 0))
      end

    Shrinker.shrink(
      sequence,
      Keyword.put(shrink_opts, :oracle, Runner.shrink_oracle(context, signature))
    )
  end
end
