defmodule ObanBench.RetryTest do
  @moduledoc """
  Value-level retry exactly-once against real Oban + Postgres.

  Oban guarantees at-least-once delivery, so a retried job re-runs `perform`.
  An idempotent worker must still land the effect exactly once. The faithful
  `IdempotentWorker` forces a retry but guards the increment with an
  `applied(job_id)` ledger, so the counter equals the number of jobs enqueued.

  Non-vacuity: a seeded non-idempotent worker re-increments on the retry, so
  the counter overshoots; PD catches the safety violation (via the resource
  poller, whose terminal-state guard sees past the transient first-attempt
  value) and shrinks it to a single Increment.
  """
  use ExUnit.Case, async: false

  alias ObanBench.Commands.Increment
  alias ObanBench.ExactlyOnce
  alias ObanBench.Retry.{Adapter, Model}

  defmodule DoubleApplyWorker do
    @moduledoc "BUG: not idempotent, so the forced retry applies the increment twice."
    use Oban.Worker, queue: :bench, max_attempts: 2

    @impl true
    def backoff(_job), do: 0

    @impl true
    def perform(%Oban.Job{args: %{"counter" => name}, attempt: attempt}) do
      ObanBench.DB.increment(name)
      if attempt < 2, do: raise("forced retry (double-applies)"), else: :ok
    end
  end

  defmodule DoubleApplyAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: ExactlyOnce.setup(config)

    @impl true
    def teardown(ctx), do: ExactlyOnce.teardown(ctx)

    @impl true
    def execute(%Increment{counter: base}, ctx) do
      ExactlyOnce.enqueue(base, nil, DoubleApplyWorker, ctx, dedup: false)
    end
  end

  describe "idempotent worker under forced retry" do
    for seed <- 1..6 do
      test "seed #{seed}: the retried effect lands exactly once" do
        assert {:ok, _stats} =
                 PropertyDamage.run(
                   model: Model,
                   adapter: Adapter,
                   seed: unquote(seed),
                   max_commands: 8,
                   max_runs: 6,
                   verbose: false
                 )
      end
    end
  end

  describe "seeded bug: non-idempotent worker double-applies on retry" do
    @seed 1

    test "the overshoot is caught and shrunk to a single increment" do
      assert {:error, report} =
               PropertyDamage.run(
                 model: Model,
                 adapter: DoubleApplyAdapter,
                 seed: @seed,
                 max_commands: 8,
                 max_runs: 6,
                 verbose: false
               )

      assert {:resource_poller_error, %ExactlyOnce.Violation{observed: 2, expected: 1}} =
               report.failure_reason

      commands = PropertyDamage.Sequence.to_list(report.shrunk_sequence)

      assert [%Increment{}] = commands,
             "a single retried increment double-applies, so one command suffices: #{inspect(commands)}"
    end
  end
end
