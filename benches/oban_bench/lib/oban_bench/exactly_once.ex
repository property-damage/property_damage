defmodule ObanBench.ExactlyOnce do
  @moduledoc """
  Shared adapter machinery for the value-level **exactly-once** benches (retry
  and uniqueness).

  Exactly-once is two properties, and they now live in different places:

    * **safety** ("the counter never EXCEEDS its expected final value") is a
      declarative `@trigger at: :teardown` assertion on each bench's projection,
      evaluated on the fully-**settled** state (DR-024). The projection
      accumulates the expected value (counting `Enqueued`, with the uniqueness
      dedup rule applied in `apply/2`) and the maximum value ever observed (from
      `Incremented`), then fails if the observed maximum exceeded the expected.
      Because the check runs on the settled state and the projection retains the
      maximum, it catches an overshoot that a `@poll_state` liveness predicate
      would miss: the value passes transiently through the expected number on
      its way to overshooting, and a liveness poller resolves on that transient
      pass and stops watching.
    * **liveness** ("the effect eventually happens") stays with the resource
      poller: it streams the database value back as `Incremented` events until
      the job reaches a terminal state, and its `on_timeout` reports a job that
      never settled.

  This adapter therefore carries no exactly-once oracle of its own: it enqueues
  the job and observes it. The expected-final value lives in the projection (the
  single source of truth), not in adapter ETS.
  """

  alias ObanBench.Events.{Enqueued, Incremented}

  @terminal ["completed", "discarded", "cancelled"]

  @doc "Adapter setup: a run-unique id isolating this run's counter rows."
  def setup(config) do
    run_id = "#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
    {:ok, Map.put(config || %{}, :run_id, run_id)}
  end

  @doc "Adapter teardown: nothing to clean up (no per-run tables)."
  def teardown(_ctx), do: :ok

  @doc """
  Enqueue `worker_mod` for `base` carrying `key`, and start a poller that
  streams the database value back as `Incremented` events until the job reaches
  a terminal state. The exactly-once oracle is the projection's
  `@trigger at: :teardown` safety check, not this adapter.
  """
  def enqueue(base, key, worker_mod, ctx) do
    name = "#{ctx.run_id}:#{base}"
    {:ok, job} = Oban.insert(worker_mod.new(%{"counter" => name, "key" => "#{key}"}))

    ctx.start_poller.(
      poll_fn: fn -> {ObanBench.DB.job_state(job.id), ObanBench.DB.value(name)} end,
      interval_ms: 20,
      timeout_ms: 3000,
      on_timeout: fn info ->
        # The job never reached a terminal state: an increment was lost / never
        # applied. This is the liveness half of exactly-once.
        {:error, {:exactly_once_undershoot, %{counter: base, info: info}}}
      end,
      handler: fn {state, value} ->
        event = %Incremented{counter: base, value: value}
        if state in @terminal, do: {:done, [event]}, else: {:inject, event}
      end
    )

    {:ok, [%Enqueued{counter: base, key: key, job_id: job.id}]}
  end
end
