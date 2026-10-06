defmodule ObanBench.Compare do
  @moduledoc """
  Two variants of one Oban system compared at every boundary through `@compare`.

  Each target gets its own adapter context: `ObanBench.Compare.Adapter.setup/1`
  mints a fresh `run_id`, so two targets on one database and one queue write
  disjoint counter rows and never read each other's jobs. A target's `config:`
  picks the worker that applies its increments (`worker:`), which is how a test
  plants a wrong amount or a job that never lands in one variant only.

  Two observations:

    * `ObanBench.Compare.Counters.counters/2` (`@compare every: 1`) is pending
      while a variant has enqueued more increments than its database shows, so
      the comparison waits at each boundary until the jobs have run, then
      compares the applied values.
    * `ObanBench.Compare.Reads.read/2` (`@compare every: ReadCounter`) looks at
      the value a `ReadCounter` probe read from the database. A read taken
      before the job ran is pending, and the comparison re-reads the probe until
      the read is fresh.
  """

  # Logical counter names. The adapter prefixes them with its run id.
  @counters [:a, :b, :c]

  def counters, do: @counters
end

defmodule ObanBench.Compare.Events.CounterRead do
  @moduledoc "A `ReadCounter` probe read `value` for `counter` from the database."
  defstruct [:counter, :value]
end

defmodule ObanBench.Compare.Commands.ReadCounter do
  @moduledoc """
  Read a counter's current value from the database.

  A probe: it changes nothing, so the comparison may run it again until every
  variant reads data that reflects the jobs enqueued before it.
  """
  use PropertyDamage.Command, execution: :probe

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:counter]

  @impl true
  def generator(overrides \\ %{}) do
    %{counter: StreamData.member_of(ObanBench.Compare.counters())}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule ObanBench.Compare.Counters do
  @moduledoc """
  Enqueued increments per counter (`expected`) and the highest value a resource
  poller has seen in the database (`observed`).

  The observation `counters/2` is pending while any counter's observed value is
  below its expected count, which is the case until the variant's jobs have run.
  Once every job has landed it returns the observed values, so a variant whose
  worker applies a wrong amount differs from the reference.
  """
  use PropertyDamage.Model.Projection

  alias ObanBench.Events.{Enqueued, Incremented}

  @impl true
  def init, do: %{expected: %{}, observed: %{}}

  @impl true
  def apply(state, %Enqueued{counter: counter}) do
    update_in(state, [:expected, counter], &((&1 || 0) + 1))
  end

  def apply(state, %Incremented{counter: counter, value: value}) do
    update_in(state, [:observed, counter], &max(&1 || 0, value))
  end

  def apply(state, _event), do: state

  @compare every: 1
  def counters(state, _root) do
    case unapplied(state) do
      [] -> state.observed
      counters -> {:pending, {:unapplied, counters}}
    end
  end

  defp unapplied(state) do
    for {counter, expected} <- Enum.sort(state.expected),
        Map.get(state.observed, counter, 0) < expected,
        do: counter
  end
end

defmodule ObanBench.Compare.Reads do
  @moduledoc """
  Enqueued increments per counter and the latest value a `ReadCounter` probe
  read.

  The observation `read/2` is pending while the latest read is below the number
  of increments enqueued for that counter: the read was taken before the job
  ran. The comparison then re-executes the probe until the read is fresh.
  """
  use PropertyDamage.Model.Projection

  alias ObanBench.Compare.Commands.ReadCounter
  alias ObanBench.Compare.Events.CounterRead
  alias ObanBench.Events.Enqueued

  @impl true
  def init, do: %{expected: %{}, read: nil}

  @impl true
  def apply(state, %Enqueued{counter: counter}) do
    update_in(state, [:expected, counter], &((&1 || 0) + 1))
  end

  def apply(state, %CounterRead{counter: counter, value: value}) do
    %{state | read: {counter, value}}
  end

  def apply(state, _event), do: state

  @compare every: ReadCounter
  def read(%{read: {counter, value}} = state, _root) do
    expected = Map.get(state.expected, counter, 0)

    if value < expected,
      do: {:pending, {:stale_read, counter, value, expected}},
      else: %{counter: counter, value: value}
  end
end

defmodule ObanBench.Compare.Simulator do
  @moduledoc "Predicts the synchronous events of `Increment` and `ReadCounter`."
  @behaviour PropertyDamage.Model.Simulator

  alias ObanBench.Commands.Increment
  alias ObanBench.Compare.Commands.ReadCounter
  alias ObanBench.Compare.Events.CounterRead
  alias ObanBench.Events.Enqueued

  @impl true
  def simulate(%Increment{counter: counter}, _state), do: [%Enqueued{counter: counter}]

  def simulate(%ReadCounter{counter: counter}, state) do
    [%CounterRead{counter: counter, value: Map.get(state.expected, counter, 0)}]
  end

  def simulate(_command, _state), do: []
end

defmodule ObanBench.Compare.Model do
  @moduledoc "Increments only, compared through `ObanBench.Compare.Counters.counters/2`."
  @behaviour PropertyDamage.Model

  alias ObanBench.Commands.Increment

  @impl true
  def commands, do: [Increment]

  @impl true
  def command_sequence_projection, do: ObanBench.Compare.Counters

  @impl true
  def check_projections, do: [ObanBench.Compare.Counters]

  @impl true
  def simulator, do: ObanBench.Compare.Simulator
end

defmodule ObanBench.Compare.ReadModel do
  @moduledoc """
  One `Increment`, then `ReadCounter` probes of that counter, compared through
  `ObanBench.Compare.Reads.read/2`.

  Nothing is compared at the `Increment` root, so the first read can run before
  the job has landed.
  """
  @behaviour PropertyDamage.Model

  alias ObanBench.Commands.Increment
  alias ObanBench.Compare.Commands.ReadCounter

  @impl true
  def commands do
    [
      {Increment, when: &nothing_enqueued?/1},
      {ReadCounter, when: &enqueued?/1, overrides: &read_overrides/1}
    ]
  end

  @impl true
  def command_sequence_projection, do: ObanBench.Compare.Reads

  @impl true
  def check_projections, do: [ObanBench.Compare.Reads]

  @impl true
  def simulator, do: ObanBench.Compare.Simulator

  def nothing_enqueued?(state), do: state.expected == %{}
  def enqueued?(state), do: state.expected != %{}

  def read_overrides(state), do: %{counter: StreamData.member_of(Map.keys(state.expected))}
end

defmodule ObanBench.Compare.Adapter do
  @moduledoc """
  Enqueues increments through a configurable worker and reads counters back.

  Config keys (all optional):

    * `:worker` - the Oban worker that applies an increment
      (default `ObanBench.IncrementWorker`)
    * `:name` - the label in messages sent to `:test_pid`
    * `:test_pid` - receives `{:read, name, counter, value}` for every read

  `setup/1` mints a run id per target, so targets that share a database and a
  queue never touch each other's rows.
  """
  use PropertyDamage.Adapter

  alias ObanBench.Commands.Increment
  alias ObanBench.Compare.Commands.ReadCounter
  alias ObanBench.Compare.Events.CounterRead

  @impl true
  def setup(config), do: ObanBench.Adapter.setup(config)

  @impl true
  def teardown(ctx), do: ObanBench.Adapter.teardown(ctx)

  @impl true
  def execute(%Increment{counter: base}, ctx, runtime) do
    worker = Map.get(ctx, :worker, ObanBench.IncrementWorker)
    ObanBench.Adapter.enqueue_increment(base, worker, ctx, runtime)
  end

  def execute(%ReadCounter{counter: base}, ctx, _runtime) do
    value = ObanBench.DB.value("#{ctx.run_id}:#{base}")

    case ctx do
      %{test_pid: pid} when is_pid(pid) -> send(pid, {:read, Map.get(ctx, :name), base, value})
      _ -> :ok
    end

    {:ok, [%CounterRead{counter: base, value: value}]}
  end
end
