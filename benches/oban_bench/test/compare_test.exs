defmodule ObanBench.CompareTest do
  @moduledoc """
  Two variants of one Oban system, compared at every boundary through
  `@compare` against real Postgres.

  Each target mints its own run id in `setup/1`, so both variants share the
  database and the queue without touching each other's rows. A target's
  `worker:` config plants the bug in one variant only.
  """
  use ExUnit.Case, async: false

  alias ObanBench.Compare.{Adapter, Counters, Model, ReadModel, Reads}
  alias PropertyDamage.{ComparisonMismatch, Failure}
  alias PropertyDamage.FailureReport.Formatter

  defmodule DoubleIncrementWorker do
    @moduledoc "BUG: applies every increment twice."
    use Oban.Worker, queue: :bench, max_attempts: 1

    @impl true
    def perform(%Oban.Job{args: %{"counter" => name}}) do
      # One statement, so no poller can see a half-applied value.
      ObanBench.Repo.query!(
        "INSERT INTO counters (name, value) VALUES ($1, 2) " <>
          "ON CONFLICT (name) DO UPDATE SET value = counters.value + 2",
        [name]
      )

      :ok
    end
  end

  defmodule NoOpWorker do
    @moduledoc "BUG: completes the job without applying the increment."
    use Oban.Worker, queue: :bench, max_attempts: 1

    @impl true
    def perform(%Oban.Job{}), do: :ok
  end

  defmodule SlowIncrementWorker do
    @moduledoc "Applies the increment 150 ms after the job starts."
    use Oban.Worker, queue: :bench, max_attempts: 1

    @impl true
    def perform(%Oban.Job{args: %{"counter" => name}}) do
      Process.sleep(150)
      ObanBench.DB.increment(name)
    end
  end

  @counters_key {Counters, :counters}
  @read_key {Reads, :read}

  defp target(name, config \\ %{}) do
    {Adapter, name: name, config: Map.merge(%{name: name, test_pid: self()}, config)}
  end

  defp run(model, targets, opts) do
    [model: model, targets: targets, max_runs: 1, seed: 7, shrink: false, verbose: false]
    |> Keyword.merge(opts)
    |> PropertyDamage.run()
  end

  defp text(report), do: Formatter.format(report, :terminal, color: false)

  test "two variants agree once every job has run, and the comparison waits for them" do
    started = System.monotonic_time(:millisecond)

    assert {:ok, stats} =
             run(Model, [target("a"), target("b")],
               max_commands: 4,
               compare: [converge_within: 3_000]
             )

    elapsed = System.monotonic_time(:millisecond) - started
    counts = Map.fetch!(stats.compare_counts, @counters_key)

    IO.puts(
      "\n[oban two-variant] compared_at=#{counts.compared_at} waited_at=#{counts.waited_at} " <>
        "waited_ms=#{counts.waited_ms} wall_ms=#{elapsed}"
    )

    # One comparison per root, and at least one root where a job had not run
    # yet when the variants reached it.
    assert counts.compared_at == 4
    assert counts.waited_at > 0
    assert counts.waited_ms > 0
  end

  test "a variant whose worker applies a wrong amount diverges from the reference" do
    targets = [target("a"), target("double", %{worker: DoubleIncrementWorker})]

    assert {:error, report} =
             run(Model, targets, max_commands: 2, compare: [converge_within: 500])

    assert report.kind == :diverged
    assert report.variant == %{index: 1, name: "double"}

    divergence = Failure.detail(report.failure_reason)
    assert divergence.key == @counters_key
    assert divergence.root == 0
    assert [{counter, 1}] = Map.to_list(divergence.reference_value)
    assert divergence.variant_value == %{counter => 2}

    assert %ComparisonMismatch{} = divergence.mismatch
    assert divergence.mismatch.left == divergence.reference_value
    assert divergence.mismatch.right == divergence.variant_value

    output = text(report)
    assert output =~ "Divergence"
    assert output =~ "ObanBench.Compare.Counters.counters"
    assert output =~ "Mismatch"

    # The mismatch renders both values, indented under its heading.
    for line <- String.split(Exception.message(divergence.mismatch), "\n") do
      assert output =~ line
    end
  end

  test "a variant whose jobs never land does not converge within the bound" do
    targets = [target("a"), target("noop", %{worker: NoOpWorker})]
    started = System.monotonic_time(:millisecond)

    assert {:error, report} =
             run(Model, targets, max_commands: 2, compare: [converge_within: 300])

    elapsed = System.monotonic_time(:millisecond) - started

    assert report.kind == :did_not_converge
    assert report.variant == %{index: 1, name: "noop"}

    convergence = Failure.detail(report.failure_reason)
    assert convergence.key == @counters_key
    assert convergence.root == 0
    assert {:unapplied, [_counter]} = convergence.reason
    assert convergence.waited_ms >= 300
    assert elapsed >= 300

    output = text(report)

    assert output =~
             "did not converge within 300 ms at root 0 in variant \"noop\""

    assert output =~ ":unapplied"
    assert output =~ "waited #{convergence.waited_ms} ms"
  end

  test "a probe that first reads stale data converges through the re-read" do
    slow = %{worker: SlowIncrementWorker}

    assert {:ok, stats} =
             run(ReadModel, [target("a", slow), target("b", slow)],
               max_commands: 2,
               compare: [converge_within: 3_000]
             )

    counts = Map.fetch!(stats.compare_counts, @read_key)
    assert counts.compared_at == 1
    assert counts.waited_at == 1

    for name <- ["a", "b"] do
      reads = reads(name)

      # The first read ran before the job landed; a later re-read saw it.
      assert [0 | _] = reads
      assert List.last(reads) == 1
      assert length(reads) >= 2
    end
  end

  # Every value `name` read, in order.
  defp reads(name) do
    receive do
      {:read, ^name, _counter, value} -> [value | reads(name)]
    after
      0 -> []
    end
  end
end
