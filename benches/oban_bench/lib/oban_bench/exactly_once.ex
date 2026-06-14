defmodule ObanBench.ExactlyOnce do
  @moduledoc """
  Shared machinery for the value-level **exactly-once** benches (retry and
  uniqueness).

  Exactly-once is two properties: a LIVENESS half (the counter eventually
  reaches the expected value) and a SAFETY half (it never EXCEEDS it). PD's
  `@poll_state` invariant expresses only liveness: it resolves as soon as
  `observed == expected` holds once, so it cannot catch an overshoot that
  develops afterwards (a non-idempotent retry double-applying, or duplicate jobs
  that were supposed to be deduplicated). Resource-poller-injected events do not
  fire synchronous assertions either, so the safety half cannot be a `@trigger`.
  (These two limitations were established empirically while building this bench;
  they are a genuine finding about PD's eventual-consistency machinery.)

  So this bench uses the resource poller as the SINGLE oracle, which is the one
  place an asynchronous observation can both stop the run with an error AND time
  out. The handler enforces:

    * **safety** -- `value > expected` for a counter is an exactly-once
      violation, failed immediately with a clear `Violation`;
    * **liveness** -- the poller only settles (`:done`) once the job has reached
      a terminal state AND `value == expected`; if that never happens within the
      timeout it fails (an increment that was lost / never applied).

  The terminal-state guard is what makes the retry overshoot detectable: at the
  transient `value == expected` after the first attempt the job is still
  `executing`/`retryable`, so the poller keeps watching and catches the second
  application. The adapter tracks the expected final value per counter in ETS,
  bumping it per logical contribution: always for the retry bench, only for a
  not-yet-seen key for the uniqueness bench.
  """

  alias ObanBench.Events.{Enqueued, Incremented}

  defmodule Violation do
    @moduledoc "Raised (as a poller error) when a counter exceeds its expected final value."
    defexception [:counter, :observed, :expected]

    @impl true
    def message(%{counter: counter, observed: observed, expected: expected}) do
      "exactly-once violated for #{inspect(counter)}: observed #{observed} exceeds expected #{expected}"
    end
  end

  @doc """
  Adapter setup: a run-unique id plus ETS tables tracking, per counter, the
  expected final value and the set of keys already counted (for dedup).
  """
  def setup(config) do
    run_id = "#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
    expected = :ets.new(:pd_exactly_once_expected, [:set, :public])
    seen = :ets.new(:pd_exactly_once_seen, [:set, :public])
    {:ok, Map.merge(config || %{}, %{run_id: run_id, expected: expected, seen: seen})}
  end

  @doc "Adapter teardown: drop the tracking tables."
  def teardown(ctx) do
    for key <- [:expected, :seen], table = Map.get(ctx, key), table != nil do
      if :ets.info(table) != :undefined, do: :ets.delete(table)
    end

    :ok
  end

  @doc """
  Enqueue `worker_mod` for `base` carrying `key`, bump this counter's expected
  final value, and start the safety-enforcing poller.

  `dedup: true` (uniqueness bench) only bumps the expected value the first time
  a `{base, key}` pair is seen, modelling Oban's deduplication. `dedup: false`
  (retry bench) bumps it on every call.
  """
  def enqueue(base, key, worker_mod, ctx, opts \\ []) do
    dedup = Keyword.get(opts, :dedup, false)
    name = "#{ctx.run_id}:#{base}"

    if not dedup or first_time?(ctx.seen, {name, key}) do
      bump(ctx.expected, name)
    end

    {:ok, job} = Oban.insert(worker_mod.new(%{"counter" => name, "key" => "#{key}"}))

    ctx.start_poller.(
      poll_fn: fn -> {ObanBench.DB.job_state(job.id), ObanBench.DB.value(name)} end,
      interval_ms: 20,
      timeout_ms: 3000,
      on_timeout: fn info ->
        # Never reached the expected value: an increment was lost / never
        # applied. This is the liveness half of exactly-once.
        {:error,
         {:exactly_once_undershoot,
          %{counter: base, expected: current(ctx.expected, name), info: info}}}
      end,
      handler: fn {state, value} ->
        expected = current(ctx.expected, name)

        cond do
          value > expected ->
            {:error, %Violation{counter: base, observed: value, expected: expected}}

          value == expected and state in ["completed", "discarded", "cancelled"] ->
            {:done, [%Incremented{counter: base, value: value}]}

          true ->
            {:inject, %Incremented{counter: base, value: value}}
        end
      end
    )

    {:ok, [%Enqueued{counter: base, key: key, job_id: job.id}]}
  end

  defp bump(table, name), do: :ets.update_counter(table, name, 1, {name, 0})
  defp current(table, name), do: :ets.lookup_element(table, name, 2, 0)

  defp first_time?(seen, pair) do
    :ets.insert_new(seen, {pair})
  end
end
