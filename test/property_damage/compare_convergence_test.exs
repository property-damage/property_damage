defmodule PropertyDamage.CompareConvergenceTest do
  # At every boundary an observation is scheduled for, the comparison evaluates
  # it in every variant. When a side is pending or the sides differ, the
  # convergence loop drains, folds, runs the async checks and evaluates again
  # until the sides agree or the convergence bound expires. A pending side is
  # never a disagreement; at the bound it did not converge, and ready sides
  # that still differ diverged.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Failure, Shrinker}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.Pay

  @ns inspect(__MODULE__)

  @header """
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Paid, Settled}

    @impl true
    def init, do: %{unsettled: %{}, settled: 0}

    @impl true
    def apply(s, %Paid{n: n, amount: a}), do: %{s | unsettled: Map.put(s.unsettled, n, a)}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
    def apply(s, _), do: s
  """

  @sources %{
    # Pending while a payment is unsettled.
    ledger: """
    defmodule #{@ns}.Ledger do
    #{@header}
      @compare every: 1
      def totals(s, _root) do
        if s.unsettled == %{},
          do: %{settled: s.settled},
          else: {:pending, {:unsettled, Map.keys(s.unsettled)}}
      end
    end
    """,
    # The same totals, returned as a value while a payment is unsettled.
    stale: """
    defmodule #{@ns}.Stale do
    #{@header}
      @compare every: 1
      def totals(s, _root), do: %{settled: s.settled}
    end
    """,
    # Pending totals, and a check on every settlement.
    guarded: """
    defmodule #{@ns}.Guarded do
    #{@header}
      @compare every: 1
      def totals(s, _root) do
        if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
      end

      @check every: Settled
      def assert_settled_nonneg(_s, %Settled{amount: amount}) do
        if amount < 0, do: PropertyDamage.fail!("negative settlement", amount: amount)
        :ok
      end
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)

    models =
      for name <- [:ledger, :stale, :guarded], into: %{} do
        projection = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(name)))
        module = Module.concat([__MODULE__, "Model", Macro.camelize(Atom.to_string(name))])
        {name, Compare.define_model!(module, [projection])}
      end

    {:ok, compiled: compiled, models: models}
  end

  defp model!(ctx, name) do
    Compare.fixture!(ctx.compiled, name)
    Map.fetch!(ctx.models, name)
  end

  defp key(ctx, name, function), do: {Compare.fixture!(ctx.compiled, name), function}

  describe "agreement" do
    test "sides that agree at every boundary continue without waiting", ctx do
      assert {:ok, stats} =
               Compare.run(model!(ctx, :ledger), [Compare.target("a"), Compare.target("b")])

      assert Compare.counts(stats, key(ctx, :ledger, :totals)) ==
               %{compared_at: 3, waited_at: 0, waited_ms: 0}
    end

    for concurrency <- [:serial, :parallel] do
      test "a pending side holds the run at its root until it agrees (#{concurrency})", ctx do
        {:ok, gate} = Agent.start_link(fn -> false end)
        model = model!(ctx, :ledger)

        targets = [Compare.target("a"), Compare.target("b", %{at: %{3 => {:gate, gate}}})]

        task =
          Task.async(fn ->
            Compare.run(model, targets,
              max_commands: 10,
              concurrency: unquote(concurrency),
              compare: [converge_within: 3_000]
            )
          end)

        assert_receive {:executed, "a", 3, Pay}, 2_000
        assert_receive {:executed, "b", 3, Pay}, 2_000
        # Root 3 is pending in "b": no variant starts root 4.
        refute_receive {:executed, _name, 4, Pay}, 300

        Agent.update(gate, fn _ -> true end)

        assert {:ok, stats} = Task.await(task, 5_000)
        assert_received {:executed, "a", 4, Pay}
        assert_received {:executed, "b", 9, Pay}

        counts = Compare.counts(stats, key(ctx, :ledger, :totals))
        assert counts.compared_at == 10
        assert counts.waited_at == 1
      end
    end

    test "a lagging side that catches up passes without waiting for the bound", ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => {:after_ms, 60}}})]

      {elapsed, result} =
        Compare.timed(fn ->
          Compare.run(model!(ctx, :ledger), targets, compare: [converge_within: 3_000])
        end)

      assert {:ok, stats} = result
      assert elapsed < 1_500

      counts = Compare.counts(stats, key(ctx, :ledger, :totals))
      assert counts.compared_at == 3
      assert counts.waited_at == 1
      assert counts.waited_ms >= 30
      assert counts.waited_ms < 1_500
    end

    test "a pending reference side is not a disagreement either", ctx do
      # The reference settles root 1 late; "b" settles at once.
      targets = [Compare.target("a", %{at: %{1 => {:after_ms, 60}}}), Compare.target("b")]

      assert {:ok, stats} =
               Compare.run(model!(ctx, :ledger), targets, compare: [converge_within: 3_000])

      assert Compare.counts(stats, key(ctx, :ledger, :totals)).waited_at == 1
    end
  end

  describe "at the bound" do
    test "a side still pending did not converge: variant, root, key, reason and time waited",
         ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => :never}})]

      assert {:error, report} =
               Compare.run(model!(ctx, :ledger), targets, compare: [converge_within: 100])

      key = key(ctx, :ledger, :totals)

      assert report.kind == :did_not_converge
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 1
      assert Failure.name(report.failure_reason) == key
      assert Shrinker.failure_signature(report.failure_reason, 1) == {:did_not_converge, key, 1}

      failure = report.failure_reason.type
      assert Map.fetch!(failure, :key) == key
      assert Map.fetch!(failure, :root) == 1
      # The reason is whatever the observation returned with :pending.
      assert Map.fetch!(failure, :reason) == {:unsettled, [1]}

      waited = Map.fetch!(failure, :waited_ms)
      assert is_integer(waited)
      assert waited >= 100

      text = Compare.text(report)
      assert text =~ ~r/did not converge within 100 ?ms at root 1 in variant "?b"?/
      assert text =~ "waited"
      assert text =~ Integer.to_string(waited)
    end

    test "ready sides that still differ diverged, carrying the mismatch", ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => {:sync, 1}}})]

      {elapsed, result} =
        Compare.timed(fn ->
          Compare.run(model!(ctx, :ledger), targets, compare: [converge_within: 300])
        end)

      assert {:error, report} = result
      # Sides that differ are re-evaluated until the bound expires.
      assert elapsed >= 300

      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 1

      divergence = report.failure_reason.type
      assert Map.fetch!(divergence, :key) == key(ctx, :ledger, :totals)
      assert Map.fetch!(divergence, :root) == 1
      assert %Pay{n: 1} = Map.fetch!(divergence, :command)

      %{settled: settled} = reference = Map.fetch!(divergence, :reference_value)
      assert Map.fetch!(divergence, :variant_value) == %{settled: settled + 1}

      mismatch = Map.fetch!(divergence, :mismatch)
      assert Compare.mismatch?(mismatch)
      assert mismatch.left == reference
      assert mismatch.right == %{settled: settled + 1}
    end

    test "a side that stays pending reports did not converge (same system as the next test)",
         ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => :never}})]

      assert {:error, report} =
               Compare.run(model!(ctx, :ledger), targets, compare: [converge_within: 100])

      assert report.kind == :did_not_converge
      assert Failure.name(report.failure_reason) == key(ctx, :ledger, :totals)
    end

    test "a side that returns a stale value reports diverged (same system as the previous test)",
         ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => :never}})]

      assert {:error, report} =
               Compare.run(model!(ctx, :stale), targets, compare: [converge_within: 100])

      assert report.kind == :diverged
      assert Failure.name(report.failure_reason) == key(ctx, :stale, :totals)
    end
  end

  describe "inside the loop" do
    test "the async checks run on events folded while the loop waits", ctx do
      # "b" settles root 1 50 ms late with a negative amount; the check on
      # Settled fails as soon as that event is folded, long before the bound.
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => {:after_ms, 50, -100}}})]

      {elapsed, result} =
        Compare.timed(fn ->
          Compare.run(model!(ctx, :guarded), targets, compare: [converge_within: 3_000])
        end)

      assert {:error, report} = result
      assert elapsed < 2_000
      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert Failure.name(report.failure_reason) == :settled_nonneg
    end
  end
end
