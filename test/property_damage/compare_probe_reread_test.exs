defmodule PropertyDamage.CompareProbeRereadTest do
  # A read root's events do not change when a queue is drained, so at a
  # boundary whose root is a probe (`execution: :probe`) each iteration of the
  # convergence loop re-executes the probe in every variant, the reference
  # included. After a mutation root the loop drains and folds only.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{Balance, Pay, Read}

  @ns inspect(__MODULE__)

  @sources %{
    balances: """
    defmodule #{@ns}.Balances do
      use PropertyDamage.Model.Projection
      alias PropertyDamage.Test.Compare.{Balance, Paid, Pay, Read, Settled}

      @impl true
      def init, do: %{unsettled: %{}, settled: 0, balance: nil, fresh: true}

      @impl true
      def apply(s, %Paid{n: n, amount: a}), do: %{s | unsettled: Map.put(s.unsettled, n, a)}
      def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
      def apply(s, %Balance{value: v, fresh: f}), do: %{s | balance: v, fresh: f}
      def apply(s, _), do: s

      @compare every: Read
      def balance(s, _root), do: if(s.fresh, do: s.balance, else: {:pending, :stale_read})

      @compare every: Pay
      def totals(s, _root) do
        if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
      end
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)
    projection = Module.concat(__MODULE__, Balances)

    models = %{
      read_then_pay:
        Compare.define_model!(Module.concat(__MODULE__, ReadThenPay), [projection], [Read, Pay]),
      pays: Compare.define_model!(Module.concat(__MODULE__, Pays), [projection], [Pay, Pay])
    }

    {:ok, compiled: compiled, models: models}
  end

  defp model!(ctx, name) do
    Compare.fixture!(ctx.compiled, :balances)
    Map.fetch!(ctx.models, name)
  end

  # "b" reads a stale balance twice before the fresh one.
  defp stale_twice, do: %{reads: [{0, false}, {0, false}, {10, true}]}

  test "every variant re-executes the probe root once per loop iteration", ctx do
    targets = [Compare.target("a"), Compare.target("b", stale_twice())]

    assert {:ok, _stats} =
             Compare.run(model!(ctx, :read_then_pay), targets,
               max_commands: 2,
               compare: [converge_within: 3_000]
             )

    executions = Compare.executions()
    # The first read, then one re-read in each of the two iterations "b"
    # needed to read fresh data; the reference is re-read alongside.
    assert Compare.count(executions, "a", 0, Read) == 3
    assert Compare.count(executions, "b", 0, Read) == 3
  end

  test "the re-reads' events are appended and folded; the stale read stays in the log", ctx do
    # Root 0 converges through the re-reads; root 1 then diverges in "b", so
    # the report carries "b"'s event log.
    targets = [
      Compare.target("a"),
      Compare.target("b", Map.put(stale_twice(), :at, %{1 => {:sync, 1}}))
    ]

    assert {:error, report} =
             Compare.run(model!(ctx, :read_then_pay), targets,
               max_commands: 2,
               compare: [converge_within: 500]
             )

    assert report.kind == :diverged
    assert report.variant == %{index: 1, name: "b"}
    assert {_projection, :totals} = Failure.name(report.failure_reason)

    balances =
      for %{command_index: 0, event: %Balance{} = event} <- FailureReport.event_log(report),
          do: {event.value, event.fresh}

    assert balances == [{0, false}, {0, false}, {10, true}]
  end

  test "after a mutation root the loop drains and folds without re-executing it", ctx do
    targets = [Compare.target("a"), Compare.target("b", %{at: %{0 => {:after_ms, 80}}})]

    assert {:ok, stats} =
             Compare.run(model!(ctx, :pays), targets,
               max_commands: 2,
               compare: [converge_within: 3_000]
             )

    projection = Compare.fixture!(ctx.compiled, :balances)
    assert Compare.counts(stats, {projection, :totals}).waited_at == 1

    executions = Compare.executions()
    assert Compare.count(executions, "a", 0, Pay) == 1
    assert Compare.count(executions, "b", 0, Pay) == 1
  end

  test "a probe whose first read is stale and whose next read is fresh converges", ctx do
    # The stale read is a ready value that differs, not a pending one.
    targets = [Compare.target("a"), Compare.target("b", %{reads: [{0, true}, {10, true}]})]

    assert {:ok, _stats} =
             Compare.run(model!(ctx, :read_then_pay), targets,
               max_commands: 2,
               compare: [converge_within: 3_000]
             )
  end
end
