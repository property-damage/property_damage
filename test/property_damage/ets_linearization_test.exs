defmodule PropertyDamage.EtsLinearizationTest do
  @moduledoc """
  Phase 6c: parallel + linearization bench against a real ETS-backed register
  (zero infrastructure). The live oracle for the linearization soundness fix.

  This complements the in-repo soundness regression (`linearization_soundness_test.exs`)
  with a DIFFERENT, richer model: a counter whose value-carrying `from -> to`
  events let the checker refute lost updates on EVENTS alone (the canonical
  linearizability example), exercising a code path the key/value model does not.

  Two directions, both proven:

  - **No false positives.** The faithful `CorrectAdapter` (atomic
    `:ets.update_counter`) is never reported as failing under branching, across
    many seeds. Pre-fix, branching over-reported races here too.
  - **Real races caught (non-vacuity).** The seeded `StaleSnapshotAdapter`
    reports every increment from a snapshot it never refreshes, so two parallel
    increments both claim `from: 0`: a lost update no serialization explains.
    PD detects it and shrinks to the minimal two-increment race.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{EventLog.Entry, Linearization, Sequence}

  alias PropertyDamage.Test.EtsRegister
  alias PropertyDamage.Test.EtsRegister.Commands.Increment
  alias PropertyDamage.Test.EtsRegister.{CorrectAdapter, Model}
  alias PropertyDamage.Test.EtsRegister.Events.Incremented

  @branching [max_branches: 2, branch_probability: 1.0]

  # Seeded bug: each increment is reported from a snapshot taken at setup and
  # never refreshed, so concurrent increments overlap into a lost update. The
  # real ETS table is still updated (so the bug is purely in what the SUT
  # *reports*, the realistic failure mode of a non-atomic read-modify-write).
  defmodule StaleSnapshotAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.EtsRegister
    alias PropertyDamage.Test.EtsRegister.Commands.{Increment, ReadValue}
    alias PropertyDamage.Test.EtsRegister.Events.{Incremented, ValueRead}

    @impl true
    def setup(_config), do: {:ok, %{table: EtsRegister.new(), snapshot: 0}}

    @impl true
    def teardown(%{table: table}) do
      if :ets.info(table) != :undefined, do: :ets.delete(table)
      :ok
    end

    @impl true
    def execute(%Increment{}, %{table: table, snapshot: snapshot}, _runtime) do
      # Persist for real, but REPORT from the stale snapshot: a lost update.
      EtsRegister.increment(table)
      {:ok, [%Incremented{from: snapshot, to: snapshot + 1}]}
    end

    def execute(%ReadValue{}, %{table: table}, _runtime) do
      {:ok, [%ValueRead{value: EtsRegister.read(table)}]}
    end
  end

  describe "atomic ETS register is never reported as failing under branching" do
    for seed <- 1..30 do
      test "seed #{seed}: linearizable" do
        result =
          PropertyDamage.run(
            model: Model,
            adapter: CorrectAdapter,
            seed: unquote(seed),
            max_commands: 20,
            max_runs: 60,
            verbose: false,
            branching: @branching
          )

        assert {:ok, _stats} = result,
               "atomic register must always be linearizable, seed #{unquote(seed)} got: #{inspect(result)}"
      end
    end
  end

  describe "atomic ETS register is also clean without branching" do
    test "linear runs hold the read-consistency invariant" do
      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: Model,
                 adapter: CorrectAdapter,
                 seed: 1,
                 max_commands: 40,
                 max_runs: 100,
                 verbose: false
               )
    end
  end

  describe "seeded bug: stale snapshot causes a detectable lost update" do
    @seed 2

    test "detected under branching and shrunk to the minimal two-increment race" do
      assert {:error, failure} =
               PropertyDamage.run(
                 model: Model,
                 adapter: StaleSnapshotAdapter,
                 seed: @seed,
                 max_commands: 20,
                 max_runs: 60,
                 verbose: false,
                 branching: @branching
               )

      commands = Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(failure))

      assert [%Increment{}, %Increment{}] = commands,
             "expected the minimal two-increment lost update, got: #{inspect(commands)}"

      # The lost update is refuted on the increment events alone (no read
      # needed), so it surfaces as a linearization failure, not an assertion.
      assert {:linearization_failed, _} = failure.failure_reason
    end

    test "the shrunk reproduction still fails" do
      assert {:error, failure} =
               PropertyDamage.run(
                 model: Model,
                 adapter: StaleSnapshotAdapter,
                 seed: @seed,
                 max_commands: 20,
                 max_runs: 60,
                 verbose: false,
                 branching: @branching
               )

      {:ok, replay} =
        PropertyDamage.Executor.run(
          PropertyDamage.FailureReport.shrunk_sequence(failure),
          Model,
          StaleSnapshotAdapter,
          adapter_config: %{}
        )

      refute replay.success
    end

    test "shrinking is deterministic across repeated runs" do
      run = fn ->
        {:error, f} =
          PropertyDamage.run(
            model: Model,
            adapter: StaleSnapshotAdapter,
            seed: @seed,
            max_commands: 20,
            max_runs: 60,
            verbose: false,
            branching: @branching
          )

        Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(f))
      end

      assert run.() == run.()
    end
  end

  describe "checker level: the lost update is refuted on events alone" do
    test "two increments both observing from: 0 has no linearization" do
      branch_commands = [[%Increment{}], [%Increment{}]]

      # The race: both increments report from: 0. Whichever serializes second
      # should have observed from: 1, so no ordering explains this.
      branch_events = %{
        0 => [incr_entry(0, 1, 0)],
        1 => [incr_entry(0, 1, 0)]
      }

      assert {:no_linearization, nil} =
               Linearization.check(branch_commands, branch_events, projections(), Model)
    end

    test "a healthy pair of increments is accepted" do
      branch_commands = [[%Increment{}], [%Increment{}]]

      branch_events = %{
        0 => [incr_entry(0, 1, 0)],
        1 => [incr_entry(1, 2, 0)]
      }

      assert {:ok, _ordering} =
               Linearization.check(branch_commands, branch_events, projections(), Model)
    end
  end

  defp projections, do: %{EtsRegister.Projection => EtsRegister.Projection.init()}

  defp incr_entry(from, to, command_index) do
    Entry.from_command(%Incremented{from: from, to: to}, command_index, timestamp: 1)
  end
end
