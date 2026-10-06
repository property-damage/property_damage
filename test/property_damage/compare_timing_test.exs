defmodule PropertyDamage.CompareTimingTest do
  # When the convergence bound starts, how far a probe root may overshoot it,
  # and how the bound relates to `@eventually` windows.
  use ExUnit.Case, async: false

  alias PropertyDamage.Failure
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{Pay, Read}

  @ns inspect(__MODULE__)

  @header """
    use PropertyDamage.Model.Projection
    alias PropertyDamage.Test.Compare.{Balance, Paid, Read, Settled}

    @impl true
    def init, do: %{unsettled: %{}, settled: 0, paid: 0, balance: nil, fresh: true}

    @impl true
    def apply(s, %Paid{n: n, amount: a}), do: %{s | unsettled: Map.put(s.unsettled, n, a), paid: s.paid + 1}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
    def apply(s, %Balance{value: v, fresh: f}), do: %{s | balance: v, fresh: f}
    def apply(s, _), do: s
  """

  @totals """
      @compare every: 1
      def totals(s, _root) do
        if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
      end
  """

  @sources %{
    ledger: """
    defmodule #{@ns}.Ledger do
    #{@header}
    #{@totals}
    end
    """,
    balances: """
    defmodule #{@ns}.Balances do
    #{@header}
      @compare every: Read
      def balance(s, _root), do: if(s.fresh, do: s.balance, else: {:pending, :stale_read})
    end
    """,
    short_window: """
    defmodule #{@ns}.ShortWindow do
    #{@header}
    #{@totals}
      @eventually after: Paid, timeout: {150, :milliseconds}, interval: {10, :milliseconds}
      def settles(_s, %Paid{n: n}), do: fn s -> not Map.has_key?(s.unsettled, n) end
    end
    """,
    long_window: """
    defmodule #{@ns}.LongWindow do
    #{@header}
    #{@totals}
      @eventually after: Paid, timeout: {600, :milliseconds}, interval: {10, :milliseconds}
      def settles(_s, %Paid{n: n}), do: fn s -> not Map.has_key?(s.unsettled, n) end
    end
    """,
    # Observes only what every variant knows at once; an @eventually waits
    # for the settlements.
    paid_count: """
    defmodule #{@ns}.PaidCount do
    #{@header}
      @compare every: 1
      def paid(s, _root), do: s.paid

      @eventually after: Paid, timeout: {3_000, :milliseconds}, interval: {10, :milliseconds}
      def settles(_s, %Paid{n: n}), do: fn s -> not Map.has_key?(s.unsettled, n) end
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)

    models =
      for {name, commands} <- [
            ledger: :pay,
            balances: [Read, Pay],
            short_window: :pay,
            long_window: :pay,
            paid_count: :pay
          ],
          into: %{} do
        projection = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(name)))
        module = Module.concat([__MODULE__, "Model", Macro.camelize(Atom.to_string(name))])
        {name, Compare.define_model!(module, [projection], commands)}
      end

    {:ok, compiled: compiled, models: models}
  end

  defp model!(ctx, name) do
    Compare.fixture!(ctx.compiled, name)
    Map.fetch!(ctx.models, name)
  end

  defp key(ctx, name, function), do: {Compare.fixture!(ctx.compiled, name), function}

  describe "the bound starts when the last variant reaches the boundary" do
    for concurrency <- [:serial, :parallel] do
      test "a slow step does not eat the bound (#{concurrency})", ctx do
        # "b" spends 400 ms inside root 1, then settles 100 ms after it
        # returns. Measured from the first arrival, the 300 ms bound would
        # expire before "b" even arrives; measured from "b"'s arrival it
        # leaves 200 ms to spare. Root 1 is not the last root, so no
        # finalization stands between arrival and comparison.
        targets = [
          Compare.target("a"),
          Compare.target("b", %{at: %{1 => {:hold_then_after, 400, 100}}})
        ]

        assert {:ok, stats} =
                 Compare.run(model!(ctx, :ledger), targets,
                   max_commands: 3,
                   concurrency: unquote(concurrency),
                   compare: [converge_within: 300]
                 )

        counts = Compare.counts(stats, key(ctx, :ledger, :totals))
        assert counts.waited_at == 1
        assert counts.waited_ms >= 50
        assert counts.waited_ms < 300
      end
    end
  end

  describe "a probe root whose settle is longer than the bound" do
    test "overshoots the bound by at most one iteration and reports the time waited", ctx do
      # Every read in "b" answers {:retry, _} 15 times (about 150 ms at the
      # 10 ms settle interval, inside the 400 ms settle timeout) and then a
      # stale balance, so "b" stays pending.
      targets = [
        Compare.target("a"),
        Compare.target("b", %{reads: [{:retries, 15, {0, false}}]})
      ]

      assert {:error, report} =
               Compare.run(model!(ctx, :balances), targets,
                 max_commands: 2,
                 compare: [converge_within: 100]
               )

      assert report.kind == :did_not_converge
      assert report.failed_at_index == 0
      assert Failure.name(report.failure_reason) == key(ctx, :balances, :balance)

      waited = Map.fetch!(report.failure_reason.type, :waited_ms)
      settle_timeout_ms = 400
      margin_ms = 250
      assert waited >= 100
      assert waited < 100 + settle_timeout_ms + margin_ms

      assert Compare.text(report) =~ Integer.to_string(waited)
    end
  end

  describe "@eventually windows" do
    test "a window that expires while the loop waits ends the run before the bound", ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => :never}})]

      {elapsed, result} =
        Compare.timed(fn ->
          Compare.run(model!(ctx, :short_window), targets, compare: [converge_within: 2_000])
        end)

      assert {:error, report} = result
      assert elapsed < 1_500
      assert report.kind == :check_failed
      assert report.variant == %{index: 1, name: "b"}
      assert Failure.kind(report.failure_reason) == :poll_timeout
    end

    test "a bound shorter than a window ends the run as did not converge", ctx do
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => :never}})]

      assert {:error, report} =
               Compare.run(model!(ctx, :long_window), targets, compare: [converge_within: 100])

      assert report.kind == :did_not_converge
      assert report.failed_at_index == 1
    end

    test "an @eventually still polling does not delay agreement", ctx do
      {:ok, gate} = Agent.start_link(fn -> false end)
      model = model!(ctx, :paid_count)
      targets = [Compare.target("a"), Compare.target("b", %{at: %{1 => {:gate, gate}}})]

      task =
        Task.async(fn -> Compare.run(model, targets, compare: [converge_within: 3_000]) end)

      # Root 2 starts while root 1 is still unsettled in "b" and its
      # @eventually is still polling.
      assert_receive {:executed, "b", 2, Pay}, 2_000
      Agent.update(gate, fn _ -> true end)

      assert {:ok, stats} = Task.await(task, 5_000)
      assert Compare.counts(stats, key(ctx, :paid_count, :paid)).waited_at == 0
    end
  end
end
