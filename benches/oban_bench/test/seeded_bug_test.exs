defmodule ObanBench.SeededBugTest do
  @moduledoc """
  Non-vacuity proof for the eventual-consistency invariant. A deliberately
  buggy worker completes its job successfully but never performs the
  increment, so the database value never catches up to what was enqueued.
  PropertyDamage must catch this via the `@poll_state` timeout and shrink it
  to the minimal reproduction (a single Increment is enough).
  """
  use ExUnit.Case, async: false

  defmodule NoOpWorker do
    @moduledoc "BUG: marks the job complete without touching the counter."
    use Oban.Worker, queue: :bench, max_attempts: 1

    @impl true
    def perform(%Oban.Job{}), do: :ok
  end

  defmodule BuggyAdapter do
    use PropertyDamage.Adapter

    alias ObanBench.Commands.Increment

    @impl true
    def setup(config), do: ObanBench.Adapter.setup(config)

    @impl true
    def teardown(ctx), do: ObanBench.Adapter.teardown(ctx)

    @impl true
    def execute(%Increment{counter: base}, ctx, runtime) do
      # Same path as the real adapter, but enqueues the no-op worker.
      ObanBench.Adapter.enqueue_increment(base, NoOpWorker, ctx, runtime)
    end
  end

  test "the silently-dropped increment is found and shrunk to a minimal reproduction" do
    result =
      PropertyDamage.run(
        model: ObanBench.Model,
        adapter: BuggyAdapter,
        max_commands: 8,
        max_runs: 20,
        verbose: false
      )

    assert {:error, report} = result

    assert %PropertyDamage.Failure{
             type: %PropertyDamage.Failure.Assertion{kind: :poll_timeout, detail: info}
           } = report.failure_reason

    assert info.triggered_by.assertion_name == :counter_eventually_consistent

    commands =
      PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))

    # A single Increment whose effect never lands is enough to violate the
    # invariant; anything beyond a couple of commands means shrinking regressed.
    assert length(commands) <= 2,
           "expected a near-minimal reproduction, got #{length(commands)} commands: " <>
             inspect(commands)

    assert Enum.all?(commands, &match?(%ObanBench.Commands.Increment{}, &1))
  end
end
