defmodule ObanBench do
  @moduledoc """
  PropertyDamage exercised against [Oban](https://hex.pm/packages/oban) on real
  Postgres: the eventual-consistency rung of the bench ladder.

  Commands enqueue async jobs; the effect (a counter increment) only becomes
  visible after Oban drains its queue. Resource pollers observe the database
  between commands and feed the values back, and a `@poll_state` invariant
  asserts the observed value eventually matches what was enqueued.
  """

  # Logical counter names the generator chooses from. The adapter namespaces
  # them per run so concurrent PropertyDamage runs never share rows.
  @counters [:a, :b, :c]

  def counters, do: @counters
end

defmodule ObanBench.Adapter do
  @moduledoc "Executes increment commands by enqueuing real Oban jobs."
  use PropertyDamage.Adapter

  alias ObanBench.Commands.Increment
  alias ObanBench.Events.{Enqueued, Incremented}

  @impl true
  def setup(config) do
    # A token unique across the whole database lifetime isolates this run's
    # counter rows from every other run. It must be globally unique, not just
    # per-VM: the container's database outlives a single `mix` invocation, so a
    # bare System.unique_integer (which resets each OS process) would collide
    # with rows left by an earlier run and read a pre-populated counter.
    run_id = "#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
    {:ok, Map.put(config || %{}, :run_id, run_id)}
  end

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%Increment{counter: base}, ctx, runtime) do
    enqueue_increment(base, ObanBench.IncrementWorker, ctx, runtime)
  end

  @doc """
  Shared execution path: enqueue `worker_mod` for `base`, start a poller that
  streams the database value back as `Incremented` events, and return the
  synchronous `Enqueued` event. Reused by the seeded-bug adapter with a buggy
  worker so the two paths differ only in the worker module.
  """
  def enqueue_increment(base, worker_mod, ctx, runtime) do
    name = "#{ctx.run_id}:#{base}"
    {:ok, job} = Oban.insert(worker_mod.new(%{"counter" => name}))

    runtime.start_poller.(
      poll_fn: fn -> {ObanBench.DB.job_state(job.id), ObanBench.DB.value(name)} end,
      interval_ms: 20,
      timeout_ms: 3000,
      # The @poll_state invariant is the oracle; the poller only streams
      # observations, so its own timeout should never fail the run.
      on_timeout: :ignore,
      handler: fn {state, value} ->
        event = %Incremented{counter: base, value: value}

        if state in ["completed", "discarded", "cancelled"] do
          {:done, [event]}
        else
          {:inject, event}
        end
      end
    )

    {:ok, [%Enqueued{counter: base, job_id: job.id}]}
  end
end
