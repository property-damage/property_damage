defmodule ObanBench.Retry do
  @moduledoc """
  Value-level retry exactly-once bench: a job that is retried must apply its
  effect only ONCE. The faithful worker forces a retry (raises on its first
  attempt) but guards the increment behind an `applied(job_id)` ledger, so the
  counter lands on exactly the number of jobs enqueued despite the re-runs. The
  seeded bug (in the test) drops the ledger, so each retry re-applies and the
  counter overshoots.

  Like the uniqueness bench, the oracle is the resource poller
  (`ObanBench.ExactlyOnce`), not `@poll_state`: only the poller's terminal-state
  guard catches the overshoot, because the counter transiently equals the
  expected value after the first attempt (before the retry doubles it).
  """

  @counters [:a, :b, :c]
  def counters, do: @counters
end

defmodule ObanBench.Retry.Projection do
  @moduledoc """
  The exactly-once oracle for the retry bench. It accumulates the expected final
  value (one per `Enqueued`, since the retry bench does not deduplicate) and the
  maximum value any poller ever observed (from `Incremented`). The safety bound
  is a settled-state `@trigger at: :teardown` check: tracking the maximum (not a
  snapshot) is what lets it catch the retry overshoot, which is still visible on
  the settled state.
  """
  use PropertyDamage.Model.Projection

  alias ObanBench.Events.{Enqueued, Incremented}

  @impl true
  def init, do: %{enqueued: %{}, observed: %{}}

  @impl true
  def apply(state, %Enqueued{counter: counter}) do
    update_in(state, [:enqueued, counter], &((&1 || 0) + 1))
  end

  def apply(state, %Incremented{counter: counter, value: value}) do
    update_in(state, [:observed, counter], &max(&1 || 0, value))
  end

  def apply(state, _event), do: state

  # Safety: a retried job must apply its effect at most once, so the observed
  # maximum must never exceed the number of increments enqueued for that counter.
  @trigger at: :teardown
  def assert_exactly_once(state, _phase) do
    for {counter, observed} <- state.observed do
      expected = Map.get(state.enqueued, counter, 0)

      if observed > expected do
        PropertyDamage.fail!("exactly-once violated (retry)",
          counter: counter,
          observed: observed,
          expected: expected
        )
      end
    end
  end
end

defmodule ObanBench.Retry.Model do
  @moduledoc "Reuses the Increment command; the poller is the exactly-once oracle."
  @behaviour PropertyDamage.Model

  alias ObanBench.Commands.Increment

  @impl true
  def commands, do: [Increment]

  @impl true
  def command_sequence_projection, do: ObanBench.Retry.Projection

  @impl true
  def assertion_projections, do: []

  @impl true
  def simulator, do: ObanBench.Simulator
end

defmodule ObanBench.Retry.IdempotentWorker do
  @moduledoc """
  Faithful worker: forces one retry (raises on attempt 1) but applies the
  increment idempotently via the `applied(job_id)` ledger, so the effect lands
  exactly once across the two attempts.
  """
  use Oban.Worker, queue: :bench, max_attempts: 2

  @impl true
  def backoff(_job), do: 0

  @impl true
  def perform(%Oban.Job{id: id, args: %{"counter" => name}, attempt: attempt}) do
    ObanBench.DB.increment_once(name, id)
    if attempt < 2, do: raise("forced retry (idempotent worker tolerates it)"), else: :ok
  end
end

defmodule ObanBench.Retry.Adapter do
  @moduledoc "Drives idempotent-under-retry increments, enforcing exactly-once."
  use PropertyDamage.Adapter

  alias ObanBench.Commands.Increment
  alias ObanBench.ExactlyOnce
  alias ObanBench.Retry.IdempotentWorker

  @impl true
  def setup(config), do: ExactlyOnce.setup(config)

  @impl true
  def teardown(ctx), do: ExactlyOnce.teardown(ctx)

  @impl true
  def execute(%Increment{counter: base}, ctx) do
    ExactlyOnce.enqueue(base, nil, IdempotentWorker, ctx)
  end
end
