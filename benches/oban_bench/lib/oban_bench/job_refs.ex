defmodule ObanBench.JobRefs do
  @moduledoc """
  `external()` server-generated-identifier bench: Oban assigns every inserted
  job a database-generated integer id, exactly the shape `external()` models.

  A producer command (`EnqueueJob`) yields an event whose `job_id` is declared
  `external()`; two distinct consumer commands (`CancelJob` and `ReadJobState`)
  receive that id, resolved by the framework from the real Oban job to a concrete
  integer before the command executes.

  Jobs are inserted far in the future (`schedule_in/0`) so the bench queue never
  runs them: each sits in the `scheduled` state. That makes cancellation
  deterministic and observable -- a correct `Oban.cancel_job/1` moves a scheduled
  job to `cancelled`; a cancel that no-ops leaves it `scheduled` (runnable). The
  projection's `cancelled_jobs_not_runnable` invariant catches the latter.

  Load-bearing claim (proved in `test/job_refs_shrink_test.exs`): when a consumer
  exposes a defect, shrinking preserves the producing `EnqueueJob` before the
  failing consumer. The framework never shrinks away the command that mints a
  consumed id -- dependency-aware shrinking keyed on placeholder position
  (DR-021).
  """

  # Far enough in the future that the `bench` queue never stages these jobs to
  # `available` during a run, so they remain `scheduled` and cancellation stays
  # deterministic.
  @schedule_in 3600
  def schedule_in, do: @schedule_in

  # Oban states in which a job may still run. A cancelled job must be in none of
  # these.
  @runnable ~w(available scheduled executing retryable)
  def runnable_states, do: @runnable
end

defmodule ObanBench.JobRefs.ScheduledWorker do
  @moduledoc """
  A worker whose jobs are scheduled far in the future and therefore never run
  during a bench run. Its only purpose is to own a real, server-generated Oban
  job id for the `external()` producer/consumer flow.
  """
  use Oban.Worker, queue: :bench, max_attempts: 1

  @impl true
  def perform(%Oban.Job{}), do: :ok
end

defmodule ObanBench.JobRefs.Events do
  @moduledoc "Events for the server-generated-id (external()) bench."

  defmodule JobEnqueued do
    @moduledoc """
    Producer event. `job_id` is minted by Postgres when the job is inserted, so
    it is declared `external()`: during generation it becomes a placeholder, and
    during execution it is captured from the real Oban job.
    """
    import PropertyDamage, only: [external: 0]

    defstruct job_id: external()
  end

  defmodule JobCancelled do
    @moduledoc "Consumer event: the job's state read back right after a cancel attempt."
    defstruct [:job_ref, :state]
  end

  defmodule JobObserved do
    @moduledoc "Consumer event: the job's state read by id (the state-probe consumer)."
    defstruct [:job_ref, :state]
  end
end

defmodule ObanBench.JobRefs.Commands.EnqueueJob do
  @moduledoc "Producer: insert a scheduled Oban job whose id is server-generated."
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides), do: StreamData.constant(%{})
end

defmodule ObanBench.JobRefs.Commands.CancelJob do
  @moduledoc "Consumer: cancel a previously enqueued job by its server-generated id."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:job_ref]

  @impl true
  def generator(overrides) do
    # job_ref is supplied by the model's `with:` (an external placeholder routed
    # from state); the base generator only needs a valid shape.
    %{job_ref: StreamData.constant(nil)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule ObanBench.JobRefs.Commands.ReadJobState do
  @moduledoc "Consumer: read a previously enqueued job's state by its server-generated id."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:job_ref]

  @impl true
  def generator(overrides) do
    %{job_ref: StreamData.constant(nil)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule ObanBench.JobRefs.Projection do
  @moduledoc """
  Tracks the server-generated job ids produced so far (`jobs`, as placeholders
  during generation) so the model can route one into a consumer, and the state
  read back after each cancel (`cancel_states`) for the safety invariant.
  """
  use PropertyDamage.Model.Projection

  alias ObanBench.JobRefs
  alias ObanBench.JobRefs.Commands.CancelJob
  alias ObanBench.JobRefs.Events.{JobCancelled, JobEnqueued, JobObserved}

  @impl true
  def init, do: %{jobs: [], cancel_states: %{}, observed: %{}}

  @impl true
  def apply(state, %JobEnqueued{job_id: job_id}) do
    # During generation job_id is a %Placeholder{}; storing it here surfaces it
    # to `Generator.external_from/2` so a consumer's `with:` can route it.
    %{state | jobs: [job_id | state.jobs]}
  end

  def apply(state, %JobCancelled{job_ref: ref, state: st}) do
    put_in(state, [:cancel_states, ref], st)
  end

  def apply(state, %JobObserved{job_ref: ref, state: st}) do
    put_in(state, [:observed, ref], st)
  end

  def apply(state, _event), do: state

  # Safety: a job you cancelled must not be left in a runnable state. A correct
  # Oban.cancel_job/1 moves a scheduled job to `cancelled`; a cancel that no-ops
  # leaves it `scheduled`, which this catches. The state is read back
  # synchronously right after the cancel, so no settling is needed.
  @trigger every: CancelJob
  def assert_cancelled_jobs_not_runnable(state, _command) do
    for {ref, st} <- state.cancel_states, st in JobRefs.runnable_states() do
      PropertyDamage.fail!("cancelled job left runnable",
        job_ref: ref,
        state: st
      )
    end
  end
end

defmodule ObanBench.JobRefs.Simulator do
  @moduledoc "Predicts the producer event so its external() job id becomes a placeholder."
  @behaviour PropertyDamage.Model.Simulator

  alias ObanBench.JobRefs.Commands.EnqueueJob
  alias ObanBench.JobRefs.Events.JobEnqueued

  @impl true
  # Leaving job_id at its external() default is what makes the framework mint a
  # placeholder for it during generation.
  def simulate(%EnqueueJob{}, _state), do: [%JobEnqueued{}]
  def simulate(_command, _state), do: []
end

defmodule ObanBench.JobRefs.Model do
  @moduledoc """
  Producer/consumer model for the external() bench: `EnqueueJob` mints a job id,
  and two gated consumers (`CancelJob`, `ReadJobState`) each route one produced
  id from state via `Generator.external_from/2`.
  """
  @behaviour PropertyDamage.Model

  alias ObanBench.JobRefs.Commands.{CancelJob, EnqueueJob, ReadJobState}
  alias PropertyDamage.Generator

  @impl true
  def commands do
    [
      EnqueueJob,
      {CancelJob, when: &has_jobs?/1, with: &route_job/1},
      {ReadJobState, when: &has_jobs?/1, with: &route_job/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: ObanBench.JobRefs.Projection

  @impl true
  def assertion_projections, do: []

  @impl true
  def simulator, do: ObanBench.JobRefs.Simulator

  defp has_jobs?(state), do: state.jobs != []

  defp route_job(state), do: %{job_ref: Generator.external_from(state, path: [:job_id])}
end

defmodule ObanBench.JobRefs.Adapter do
  @moduledoc """
  Faithful adapter: `EnqueueJob` inserts a scheduled Oban job and returns its
  server-generated id via the external() field; `CancelJob` cancels by that id;
  `ReadJobState` reads it back. The `cancel/1` seam is public so the seeded-bug
  adapter can override just the cancel while reusing the rest.
  """
  use PropertyDamage.Adapter

  alias ObanBench.JobRefs
  alias ObanBench.JobRefs.Commands.{CancelJob, EnqueueJob, ReadJobState}
  alias ObanBench.JobRefs.Events.{JobCancelled, JobEnqueued, JobObserved}

  @impl true
  def setup(config), do: {:ok, config || %{}}

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%EnqueueJob{}, _ctx, _runtime) do
    {:ok, job} = Oban.insert(JobRefs.ScheduledWorker.new(%{}, schedule_in: JobRefs.schedule_in()))
    {:ok, [%JobEnqueued{job_id: job.id}]}
  end

  def execute(%CancelJob{job_ref: job_id}, _ctx, _runtime) do
    cancel(job_id)
    {:ok, [%JobCancelled{job_ref: job_id, state: ObanBench.DB.job_state(job_id)}]}
  end

  def execute(%ReadJobState{job_ref: job_id}, _ctx, _runtime) do
    {:ok, [%JobObserved{job_ref: job_id, state: ObanBench.DB.job_state(job_id)}]}
  end

  @doc "The real cancel. Overridden by the seeded-bug adapter to expose a defect."
  def cancel(job_id) do
    Oban.cancel_job(job_id)
    :ok
  end
end
