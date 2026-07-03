defmodule PropertyDamage.ShrinkerHierarchicalTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.{Executor, Placeholder, PlaceholderRegistry, Sequence, Shrinker}
  alias PropertyDamage.Shrinker.Config

  alias PropertyDamage.Test.Commands.Link
  alias PropertyDamage.Test.Events.LinkAdded
  alias PropertyDamage.Test.{LinkAdapter, LinkModel}

  # ============================================================================
  # Hierarchical shrinking end-to-end coverage.
  #
  # Every other shrinker test is <= the granularity threshold (8) and so never
  # reaches `hierarchical_shrink/1`. These tests drive a sequence that is both
  # long enough to trigger the hierarchical strategy AND has a multi-level
  # dependency graph with a position/depth inversion, which is precisely where
  # the strategy used to corrupt its indices after the first accepted removal.
  #
  # Dependencies are expressed with external() placeholders (DR-021): each
  # non-first Link consumes the previous Link's external id via its `:parent`,
  # a %Placeholder{} whose structured position points at the producing command.
  # ============================================================================

  # A producer/consumer chain of zero-weight Links (each consumes the previous
  # one's external id), followed by a single heavy independent Link. The chain
  # is pure filler; the heavy Link alone reproduces the failure. Because the
  # heavy Link is positioned LAST but sits at depth 0, removing a deep chain
  # node leaves a non-contiguous surviving set — the case stale indices got
  # wrong.
  defp chain_with_trailing_heavy(chain_length) do
    # parents[i] is the placeholder Link i consumes (nil for the first Link).
    # Link i consumes the external produced at index i - 1.
    parents =
      for i <- 0..(chain_length - 1) do
        if i == 0, do: nil, else: Placeholder.new_at(LinkAdded, [:ref], Position.prefix(i - 1), 0)
      end

    registry =
      parents
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(PlaceholderRegistry.new(), fn ph, reg ->
        PlaceholderRegistry.register(reg, ph)
      end)

    chain = Enum.map(parents, fn parent -> %Link{parent: parent, weight: 0} end)
    heavy = %Link{parent: nil, weight: 101}

    (chain ++ [heavy])
    |> Sequence.linear()
    |> Sequence.with_registry(registry)
  end

  defp run_and_shrink(sequence, config) do
    {:ok, result} = Executor.run(sequence, LinkModel, LinkAdapter)
    refute result.success

    Shrinker.shrink(sequence,
      failed_at_index: result.failed_at_index,
      failure_reason: result.failure_reason,
      model: LinkModel,
      adapter: LinkAdapter,
      config: config
    )
  end

  describe "hierarchical shrinking (sequences above the granularity threshold)" do
    test "reaches the minimal reproduction on a long multi-level sequence" do
      # 8-node chain + heavy = 9 commands, above the default threshold of 8.
      sequence = chain_with_trailing_heavy(8)
      assert length(Sequence.to_list(sequence)) > Config.new().granularity_threshold

      result = run_and_shrink(sequence, Config.new(shrink_arguments: false))

      shrunk = Sequence.to_list(result.sequence)
      assert length(shrunk) == 1
      assert hd(shrunk).weight == 101
    end

    test "reaches the minimal reproduction under a tight iteration budget" do
      # This is the regression guard for the index-space bug. The fix tracks
      # surviving nodes in the original index space and skips no-op levels, so
      # it converges in ~11 iterations. The previous implementation re-derived
      # indices from the progressively-shrunk list; after the first removal it
      # spent its whole budget on no-op acceptances and wrong-target removals,
      # leaving the full chain behind. A budget of 20 cleanly separates them:
      # the fixed strategy finishes minimal, the broken one was stuck at 7+.
      sequence = chain_with_trailing_heavy(8)

      result =
        run_and_shrink(sequence, Config.new(shrink_arguments: false, max_iterations: 20))

      shrunk = Sequence.to_list(result.sequence)
      assert length(shrunk) == 1, "expected minimal repro, got #{length(shrunk)} commands"
      assert hd(shrunk).weight == 101
    end

    test "is deterministic across repeated runs" do
      sequence = chain_with_trailing_heavy(8)
      config = Config.new(shrink_arguments: false)

      r1 = run_and_shrink(sequence, config)
      r2 = run_and_shrink(sequence, config)

      assert Sequence.to_list(r1.sequence) == Sequence.to_list(r2.sequence)
      assert r1.iterations == r2.iterations
    end

    test "the shrunk reproduction still fails with the same failure type" do
      sequence = chain_with_trailing_heavy(8)
      result = run_and_shrink(sequence, Config.new(shrink_arguments: false))

      {:ok, replayed} = Executor.run(result.sequence, LinkModel, LinkAdapter)
      refute replayed.success
      assert match?({:assertion_failed, :weight_limit, _}, replayed.failure_reason)
    end
  end

  describe "nil failure signature hardening" do
    test "does not accept a self-inflicted dangling-placeholder error as a reproduction" do
      # Two Links where the second consumes the first's external id and carries
      # all the weight. The real failure is the assertion firing on the heavy
      # second command; removing the first command strands the second's
      # placeholder, which fails with a `:ref_resolution_error` — a pure shrink
      # artifact (unresolved placeholders flow through the same resolution-error
      # wrapper as legacy refs).
      #
      # With no `:failure_reason` there is no signature to preserve, so the old
      # shrinker accepted ANY failure and would have returned the broken
      # single-command sequence as the "minimal repro". The hardening rejects
      # resolution failures on the nil-signature path, so the producer must stay
      # and the reproduction keeps reproducing the real failure.
      ph = Placeholder.new_at(LinkAdded, [:ref], Position.prefix(0), 0)
      registry = PlaceholderRegistry.new() |> PlaceholderRegistry.register(ph)

      producer = %Link{parent: nil, weight: 0}
      consumer = %Link{parent: ph, weight: 101}

      sequence =
        [producer, consumer]
        |> Sequence.linear()
        |> Sequence.with_registry(registry)

      {:ok, result} = Executor.run(sequence, LinkModel, LinkAdapter)
      refute result.success
      assert result.failed_at_index == 1

      shrunk =
        Shrinker.shrink(sequence,
          failed_at_index: result.failed_at_index,
          # no :failure_reason on purpose — exercises the nil-signature path
          model: LinkModel,
          adapter: LinkAdapter,
          config: Config.new(shrink_arguments: false)
        )

      {:ok, replayed} = Executor.run(shrunk.sequence, LinkModel, LinkAdapter)
      refute replayed.success
      refute match?({:ref_resolution_error, _}, replayed.failure_reason)
      assert match?({:assertion_failed, :weight_limit, _}, replayed.failure_reason)
    end
  end
end
