defmodule PropertyDamage.CompareCountersTest do
  # Per `@compare` key, a run counts the boundaries it was compared at, the
  # boundaries it waited at, and the total time it waited. The counts are on
  # the run's stats and on a failure report, beside the check fire counts.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Persistence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.Compare

  @ns inspect(__MODULE__)

  @sources %{
    counted: """
    defmodule #{@ns}.Counted do
      use PropertyDamage.Model.Projection
      alias PropertyDamage.Test.Compare.{Paid, Read, Settled}

      @impl true
      def init, do: %{unsettled: %{}, settled: 0, paid: 0}

      @impl true
      def apply(s, %Paid{n: n, amount: a}), do: %{s | unsettled: Map.put(s.unsettled, n, a), paid: s.paid + 1}
      def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
      def apply(s, _), do: s

      @compare every: 1
      def totals(s, _root) do
        if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
      end

      @compare every: 2
      def paid(s, _root), do: s.paid

      # No Read root is ever generated: this schedule never fires.
      @compare every: Read
      def never(s, _root), do: s.paid
    end
    """
  }

  setup_all do
    compiled = Compare.compile_all(@sources)

    model =
      Compare.define_model!(Module.concat(__MODULE__, Model), [Module.concat(__MODULE__, Counted)])

    {:ok, compiled: compiled, model: model}
  end

  defp model!(ctx) do
    Compare.fixture!(ctx.compiled, :counted)
    ctx.model
  end

  defp keys(ctx) do
    counted = Compare.fixture!(ctx.compiled, :counted)
    {{counted, :totals}, {counted, :paid}, {counted, :never}}
  end

  # Root 1 settles 60 ms late in "b"; with `diverge_at`, "b" also settles that
  # root with one more.
  defp targets(diverge_at, late_ms \\ 60) do
    at = %{1 => {:after_ms, late_ms}}
    at = if diverge_at, do: Map.put(at, diverge_at, {:sync, 1}), else: at
    [Compare.target("a"), Compare.target("b", %{at: at})]
  end

  defp failed_report(ctx) do
    assert {:error, report} =
             Compare.run(model!(ctx), targets(2),
               max_commands: 4,
               compare: [converge_within: 300]
             )

    assert report.kind == :diverged
    report
  end

  test "each key counts its boundaries, waits and time waited on the stats", ctx do
    {totals, paid, never} = keys(ctx)

    # 500 ms late: the comparison reaches root 1 well before "b"
    # settles it, even on a loaded machine, so it must wait.
    assert {:ok, stats} =
             Compare.run(model!(ctx), targets(nil, 500),
               max_commands: 4,
               compare: [converge_within: 3_000]
             )

    counts = Compare.field(stats, :compare_counts)
    assert counts |> Map.keys() |> Enum.sort() == Enum.sort([totals, paid, never])

    assert %{compared_at: 4, waited_at: 1, waited_ms: waited_ms} = counts[totals]
    # The 500 ms delay starts when "b" executes the root, before the
    # comparison starts waiting, so the time waited has no tight lower
    # bound: it is positive and below the convergence window.
    assert waited_ms > 0
    assert waited_ms < 3_000

    # Two observations of one projection are two keys with their own counts.
    assert counts[paid] == %{compared_at: 2, waited_at: 0, waited_ms: 0}
    # A declared schedule that never fired shows 0.
    assert counts[never] == %{compared_at: 0, waited_at: 0, waited_ms: 0}

    # Beside the check fire counts.
    assert Map.has_key?(stats, :check_fires)
  end

  test "a failure report carries the counts", ctx do
    {totals, paid, never} = keys(ctx)
    report = failed_report(ctx)

    assert {_projection, :totals} = Failure.name(report.failure_reason)
    counts = Compare.field(report, :compare_counts)

    # Root 0 agreed, root 1 waited and agreed, root 2 waited and diverged.
    assert %{compared_at: 3, waited_at: 2} = counts[totals]
    assert counts[paid].compared_at == 1
    assert counts[never] == %{compared_at: 0, waited_at: 0, waited_ms: 0}
  end

  test "the JSON export holds one count per key, and the report prints the failing key's wait",
       ctx do
    # The printed report shows the wait of the observation that failed (DR-055);
    # the counts of every key are in the export.
    {totals, paid, never} = keys(ctx)
    report = failed_report(ctx)
    exported = report |> Persistence.export_json() |> Jason.decode!()

    for {projection, function} <- [totals, paid, never] do
      label = "#{inspect(projection)}.#{function}"

      assert %{"compared_at" => _, "waited_at" => _, "waited_ms" => _} =
               exported["compare_counts"][label]
    end

    assert Compare.text(report) =~
             ~r/^Compared\s+using ==, still differing after \d+ ms \(bound 300 ms\)$/m
  end

  test "the :json format holds the same compare_counts as the export", ctx do
    report = failed_report(ctx)
    exported = report |> Persistence.export_json() |> Jason.decode!()
    formatted = report |> Formatter.format(:json) |> Jason.decode!()

    assert map_size(exported["compare_counts"]) == 3, "control: three observations are counted"
    assert Map.fetch!(formatted, "compare_counts") == exported["compare_counts"]
  end

  @tag :tmp_dir
  test "the counts survive saving and loading the report", %{tmp_dir: dir} = ctx do
    report = failed_report(ctx)

    assert {:ok, path} = Persistence.save(report, dir)
    assert {:ok, loaded} = Persistence.load(path)
    assert Compare.field(loaded, :compare_counts) == Compare.field(report, :compare_counts)
  end
end
