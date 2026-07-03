defmodule ObanBench.JobRefsTest do
  @moduledoc """
  Server-generated job ids (`external()`) end to end against real Oban + Postgres.

  `EnqueueJob` produces a job whose id is minted by the database (declared
  `external()`); two distinct consumers (`CancelJob`, `ReadJobState`) receive the
  resolved concrete id. Faithful cancellation keeps the invariant, so a run over
  many sequences is green.

  This is also the control (no-false-positive) half of the seeded-bug proof in
  `ObanBench.JobRefsShrinkTest`, and it proves the `when:`-gated consumers really
  ran: without the simulator minting the `JobEnqueued` placeholder, `state.jobs`
  would stay empty, the gate would never open, and the consumers would be
  silently never generated (the simulator trap). Non-zero coverage counts refute
  that.
  """
  use ExUnit.Case, async: false

  alias ObanBench.JobRefs.Commands.{CancelJob, ReadJobState}
  alias ObanBench.JobRefs.{Adapter, Model}

  describe "faithful cancel over generated sequences" do
    for seed <- 1..3 do
      test "seed #{seed}: cancelled jobs are never left runnable" do
        assert {:ok, _stats} =
                 PropertyDamage.run(
                   model: Model,
                   adapter: Adapter,
                   seed: unquote(seed),
                   max_commands: 12,
                   max_runs: 12,
                   verbose: false
                 )
      end
    end
  end

  test "both when:-gated consumers are actually exercised (simulator trap)" do
    assert {:ok, stats} =
             PropertyDamage.run(
               model: Model,
               adapter: Adapter,
               seed: 1,
               max_commands: 12,
               max_runs: 25,
               coverage: true,
               verbose: false
             )

    counts = stats.coverage.command_counts

    assert Map.get(counts, CancelJob, 0) > 0,
           "CancelJob never ran: the gated consumer was not generated (#{inspect(counts)})"

    assert Map.get(counts, ReadJobState, 0) > 0,
           "ReadJobState never ran: the gated consumer was not generated (#{inspect(counts)})"
  end
end
