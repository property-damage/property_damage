defmodule ObanBench.Uniqueness do
  @moduledoc """
  Value-level uniqueness bench: enqueuing the same logical job twice must
  increment the counter only ONCE (Oban's `unique` deduplication), so the final
  value equals the number of DISTINCT keys, not the number of enqueues.

  The model dedupes keys to predict the expected value (liveness, via
  `@poll_state`); the adapter enforces the exactly-once safety bound in the
  resource poller (`ObanBench.ExactlyOnce`). The faithful `UniqueWorker` carries
  an Oban `unique` constraint; the seeded bug (in the test) drops it so
  duplicates run and the counter overshoots.
  """

  # Logical counters and dedup keys the generator draws from. A small key space
  # makes duplicate {counter, key} pairs collide often within a run, which is
  # exactly what the uniqueness constraint must absorb.
  @counters [:a, :b]
  @keys [:x, :y]

  def counters, do: @counters
  def keys, do: @keys
end

defmodule ObanBench.Uniqueness.Commands.UniqueIncrement do
  @moduledoc "Enqueue an increment tagged with a dedup key."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:counter, :key]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      counter: StreamData.member_of(ObanBench.Uniqueness.counters()),
      key: StreamData.member_of(ObanBench.Uniqueness.keys())
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule ObanBench.Uniqueness.Projection do
  @moduledoc """
  Tracks the distinct keys and observed values per counter for diagnostics.

  The exactly-once oracle itself lives in the resource poller
  (`ObanBench.ExactlyOnce`): liveness via its timeout, safety via its overshoot
  check. This projection carries no assertion, so it is purely descriptive.
  """
  use PropertyDamage.Model.Projection

  alias ObanBench.Events.{Enqueued, Incremented}

  @impl true
  def init, do: %{keys: %{}, observed: %{}}

  @impl true
  def apply(state, %Enqueued{counter: counter, key: key}) do
    update_in(state, [:keys, counter], fn set -> MapSet.put(set || MapSet.new(), key) end)
  end

  def apply(state, %Incremented{counter: counter, value: value}) do
    update_in(state, [:observed, counter], &max(&1 || 0, value))
  end

  def apply(state, _event), do: state

  # Safety: each DISTINCT {counter, key} must increment the counter at most once,
  # so the observed maximum must never exceed the number of distinct keys
  # enqueued for that counter. Evaluated on the settled state (DR-024).
  @trigger at: :teardown
  def assert_exactly_once(state, _phase) do
    for {counter, observed} <- state.observed do
      expected = state.keys |> Map.get(counter, MapSet.new()) |> MapSet.size()

      if observed > expected do
        PropertyDamage.fail!("exactly-once violated (uniqueness)",
          counter: counter,
          observed: observed,
          expected: expected
        )
      end
    end
  end
end

defmodule ObanBench.Uniqueness.Simulator do
  @moduledoc "Predicts the synchronous enqueue event (carrying the dedup key)."
  @behaviour PropertyDamage.Model.Simulator

  alias ObanBench.Events.Enqueued
  alias ObanBench.Uniqueness.Commands.UniqueIncrement

  @impl true
  def simulate(%UniqueIncrement{counter: counter, key: key}, _state) do
    [%Enqueued{counter: counter, key: key}]
  end

  def simulate(_command, _state), do: []
end

defmodule ObanBench.Uniqueness.Model do
  @moduledoc "Ties the unique-increment command to the dedup-aware projection."
  @behaviour PropertyDamage.Model

  alias ObanBench.Uniqueness.Commands.UniqueIncrement

  @impl true
  def commands, do: [UniqueIncrement]

  @impl true
  def command_sequence_projection, do: ObanBench.Uniqueness.Projection

  # The command-sequence projection already carries the @trigger at: :teardown
  # safety check and receives every command/event, so it need not be listed
  # again here (doing so would evaluate the check twice).
  @impl true
  def assertion_projections, do: []

  @impl true
  def simulator, do: ObanBench.Uniqueness.Simulator
end

defmodule ObanBench.Uniqueness.UniqueWorker do
  @moduledoc """
  Faithful worker: an Oban `unique` constraint deduplicates jobs with the same
  {counter, key} args, so each distinct key increments the counter exactly once.
  """
  use Oban.Worker,
    queue: :bench,
    max_attempts: 1,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:counter, :key],
      states: [
        :available,
        :scheduled,
        :executing,
        :retryable,
        :completed,
        :discarded,
        :cancelled,
        :suspended
      ]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"counter" => name}}) do
    ObanBench.DB.increment(name)
  end
end

defmodule ObanBench.Uniqueness.Adapter do
  @moduledoc "Drives unique increments, enforcing the exactly-once safety bound."
  use PropertyDamage.Adapter

  alias ObanBench.ExactlyOnce
  alias ObanBench.Uniqueness.Commands.UniqueIncrement
  alias ObanBench.Uniqueness.UniqueWorker

  @impl true
  def setup(config), do: ExactlyOnce.setup(config)

  @impl true
  def teardown(ctx), do: ExactlyOnce.teardown(ctx)

  @impl true
  def execute(%UniqueIncrement{counter: base, key: key}, ctx, runtime) do
    ExactlyOnce.enqueue(base, key, UniqueWorker, ctx, runtime)
  end
end
