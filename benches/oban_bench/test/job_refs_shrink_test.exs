defmodule ObanBench.JobRefsShrinkTest do
  @moduledoc """
  The load-bearing claim of the `external()` bench: **shrinking preserves the
  producer of a consumed placeholder.**

  A seeded-bug adapter whose `CancelJob` silently no-ops leaves the cancelled job
  in the `scheduled` (runnable) state, violating the projection's
  `cancelled_jobs_not_runnable` invariant. The minimal reproduction is a
  producer/consumer pair: an `EnqueueJob` (which mints the server-generated id)
  followed by the failing `CancelJob` (which consumes it). PropertyDamage must
  catch the violation and shrink it to exactly that pair, keeping the producing
  `EnqueueJob` before the consumer. If dependency-aware shrinking (DR-021) ever
  dropped the producer, the consumer's placeholder could not resolve and the
  failure would not reproduce -- so retaining the producer is a hard requirement,
  not an optimization.

  `ObanBench.JobRefsTest` is the paired control proving the faithful adapter does
  not trip this invariant (no false positive).
  """
  use ExUnit.Case, async: false

  alias ObanBench.JobRefs
  alias ObanBench.JobRefs.Commands.{CancelJob, EnqueueJob, ReadJobState}
  alias ObanBench.JobRefs.Model
  alias PropertyDamage.{FailureReport, Sequence}

  defmodule BuggyCancelAdapter do
    @moduledoc """
    BUG: `CancelJob` never calls `Oban.cancel_job/1`, so the job stays
    `scheduled` (runnable). Enqueue and read use the faithful adapter unchanged,
    so the two paths differ only in whether the cancel actually happens.
    """
    use PropertyDamage.Adapter

    alias ObanBench.JobRefs.Adapter
    alias ObanBench.JobRefs.Commands.{CancelJob, EnqueueJob, ReadJobState}
    alias ObanBench.JobRefs.Events.JobCancelled

    @impl true
    def setup(config), do: Adapter.setup(config)

    @impl true
    def teardown(ctx), do: Adapter.teardown(ctx)

    @impl true
    def execute(%CancelJob{job_ref: job_id}, _ctx, _runtime) do
      # No cancel performed; the state we read back is still runnable.
      {:ok, [%JobCancelled{job_ref: job_id, state: ObanBench.DB.job_state(job_id)}]}
    end

    def execute(%EnqueueJob{} = cmd, ctx, runtime), do: Adapter.execute(cmd, ctx, runtime)
    def execute(%ReadJobState{} = cmd, ctx, runtime), do: Adapter.execute(cmd, ctx, runtime)
  end

  test "the un-cancelled job is caught and shrinks to producer + consumer, producer retained" do
    assert {:error, report} =
             PropertyDamage.run(
               model: Model,
               adapter: BuggyCancelAdapter,
               seed: 1,
               max_commands: 10,
               max_runs: 12,
               verbose: false
             )

    # A clean invariant violation: a cancelled job was observed still runnable.
    assert {:assertion_failed, name, %PropertyDamage.AssertionFailed{} = failure} =
             report.failure_reason

    assert name == :cancelled_jobs_not_runnable
    assert failure.data.state in JobRefs.runnable_states()

    commands = Sequence.to_list(FailureReport.shrunk_sequence(report))

    # The minimal reproduction is exactly the producer + failing consumer, and
    # the producing EnqueueJob comes before the CancelJob that consumes its id.
    assert [%EnqueueJob{}, %CancelJob{}] = commands,
           "expected [EnqueueJob, CancelJob]; the producer must be preserved before " <>
             "the consumer, got: #{inspect(commands)}"

    refute Enum.any?(commands, &match?(%ReadJobState{}, &1))
  end
end
