defmodule ObanBench.UniquenessTest do
  @moduledoc """
  Value-level uniqueness (exactly-once) against real Oban + Postgres.

  The faithful `UniqueWorker` deduplicates jobs by {counter, key}, so the
  counter equals the number of DISTINCT keys enqueued, never the number of
  enqueues. Both halves are checked: liveness via the model's `@poll_state`
  (the value reaches the deduplicated expected) and safety via the resource
  poller (the value never EXCEEDS it, see `ObanBench.ExactlyOnce`).

  Non-vacuity: a seeded `NonUniqueWorker` drops the unique constraint, so
  duplicate jobs all run and the counter overshoots; PD catches the safety
  violation and shrinks it to the minimal two-duplicate reproduction.
  """
  use ExUnit.Case, async: false

  alias ObanBench.ExactlyOnce
  alias ObanBench.Uniqueness.Commands.UniqueIncrement
  alias ObanBench.Uniqueness.{Adapter, Model}

  defmodule NonUniqueWorker do
    @moduledoc "BUG: no unique constraint, so duplicate {counter, key} jobs all run."
    use Oban.Worker, queue: :bench, max_attempts: 1

    @impl true
    def perform(%Oban.Job{args: %{"counter" => name}}), do: ObanBench.DB.increment(name)
  end

  defmodule NonUniqueAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: ExactlyOnce.setup(config)

    @impl true
    def teardown(ctx), do: ExactlyOnce.teardown(ctx)

    @impl true
    def execute(%UniqueIncrement{counter: base, key: key}, ctx, runtime) do
      # Same path as the correct adapter, but a worker that never deduplicates:
      # the counter will overshoot when a key repeats.
      ExactlyOnce.enqueue(base, key, NonUniqueWorker, ctx, runtime)
    end
  end

  describe "faithful unique worker" do
    for seed <- 1..8 do
      test "seed #{seed}: deduplicated, exactly-once holds" do
        assert {:ok, _stats} =
                 PropertyDamage.run(
                   model: Model,
                   adapter: Adapter,
                   seed: unquote(seed),
                   max_commands: 10,
                   max_runs: 8,
                   verbose: false
                 )
      end
    end
  end

  describe "seeded bug: missing unique constraint overshoots" do
    @seed 1

    test "the duplicate-run overshoot is caught and shrunk to two duplicate increments" do
      assert {:error, report} =
               PropertyDamage.run(
                 model: Model,
                 adapter: NonUniqueAdapter,
                 seed: @seed,
                 max_commands: 10,
                 max_runs: 8,
                 verbose: false
               )

      # A clean exactly-once safety violation: the @trigger at: :teardown check
      # saw the counter overshoot its deduplicated expected value (the duplicate
      # job ran a second time).
      assert {:assertion_failed, :exactly_once,
              %PropertyDamage.AssertionFailed{data: %{observed: 2, expected: 1}}} =
               report.failure_reason

      commands = PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))

      assert [%UniqueIncrement{counter: c, key: k}, %UniqueIncrement{counter: c, key: k}] =
               commands,
             "expected two identical {counter, key} increments, got: #{inspect(commands)}"
    end
  end
end
