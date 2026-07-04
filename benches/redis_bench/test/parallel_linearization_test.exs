defmodule RedisBench.ParallelLinearizationTest do
  @moduledoc """
  Branching (parallel) execution + linearization checking against real Redis.

  Redis `INCR` is atomic and linearizable; a `GET`-then-`SET` read-modify-write
  is two round-trips and can lose an update under concurrency. This suite proves
  both, in two layers:

  ## Layer 1 -- the race is physical (`describe "physical race ..."`)

  Two real Redis connections run the read-modify-write with a barrier that
  guarantees BOTH read before EITHER writes (deterministic, no timing luck): the
  non-atomic `GET`-then-`SET` leaves the register at 1 after two increments (a
  lost update), while atomic `INCR` under the identical schedule leaves it at 2.
  This is why `GetThenSet`, not `Increment`, is the racing command.

  ## Layer 2 -- the framework detects it (the remaining describes)

  `PropertyDamage.run(..., branching:)` records each branch's observed write
  events and asks `PropertyDamage.Linearization` whether any sequential ordering
  explains them.

  - **No false positives.** Atomic `Increment` branches (`RedisBench.Model`) and
    faithful `GetThenSet` branches (`RedisBench.RmwModel` + `RedisBench.Adapter`)
    are never reported as failing, across many seeds.
  - **Real races caught (non-vacuity, RED-first).** `LostUpdateAdapter` computes
    every `GetThenSet` from a snapshot taken at connect time and never refreshed
    -- the realistic failure mode of a non-atomic read-modify-write -- so two
    concurrent writes both claim `from: 0`. No serialization explains that, and
    PropertyDamage refutes it with a `:linearization_failed` failure and shrinks
    to the minimal two-`GetThenSet` race. The SET is real, so the register is
    physically left at the lost-update value.

  ## Note on how the framework schedules branches (verified 2026-07-03)

  The executor runs branches SEQUENTIALLY over one shared adapter context
  (`PropertyDamage.Executor.Branching`, an `Enum.map`), then checks
  linearizability of the observed events analytically -- it does NOT run branches
  concurrently over separate connections. A faithful `GetThenSet` adapter is
  therefore always linearizable through the framework (each branch observes the
  prior branch's write), which is exactly why the lost update is injected at the
  adapter level (the stale snapshot), the same technique the framework's own
  `test/property_damage/ets_linearization_test.exs` uses. Layer 1 supplies the
  genuine physical race that grounds the adapter's modeled failure in reality.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{EventLog.Entry, FailureReport, Linearization, Sequence}
  alias RedisBench.Commands.{GetThenSet, ReadValue}
  alias RedisBench.Conn
  alias RedisBench.Events.Written

  @branching [max_branches: 2, branch_probability: 1.0]

  # Seeded bug: report every read-modify-write from a snapshot captured at
  # connect time and never refreshed. Two concurrent GetThenSets both read the
  # stale snapshot and both write the same value -- a lost update no serial
  # ordering explains. The SET is real, so Redis is genuinely left one short.
  defmodule LostUpdateAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias RedisBench.Commands.{GetThenSet, ReadValue}
    alias RedisBench.Conn
    alias RedisBench.Events.{ValueRead, Written}

    @impl true
    def setup(_config) do
      {:ok, conn} = Conn.start_direct()
      key = Conn.run_key()
      {:ok, raw} = Redix.command(conn, ["GET", key])
      {:ok, %{conn: conn, key: key, snapshot: to_int(raw)}}
    end

    @impl true
    def teardown(%{conn: conn}) do
      Redix.stop(conn)
      :ok
    end

    @impl true
    def execute(%GetThenSet{}, %{conn: conn, key: key, snapshot: snapshot}, _runtime) do
      to = snapshot + 1
      {:ok, _} = Redix.command(conn, ["SET", key, Integer.to_string(to)])
      {:ok, [%Written{from: snapshot, to: to}]}
    end

    def execute(%ReadValue{}, %{conn: conn, key: key}, _runtime) do
      {:ok, raw} = Redix.command(conn, ["GET", key])
      {:ok, [%ValueRead{value: to_int(raw)}]}
    end

    defp to_int(nil), do: 0
    defp to_int(v) when is_binary(v), do: String.to_integer(v)
  end

  describe "physical race over two real Redis connections" do
    test "non-atomic GET-then-SET loses an update: register ends at 1, not 2" do
      final =
        run_race(
          fn conn, key -> to_int(Redix.command!(conn, ["GET", key])) end,
          fn conn, key, v -> Redix.command!(conn, ["SET", key, Integer.to_string(v + 1)]) end
        )

      assert final == "1",
             "two non-atomic read-modify-writes should lose one update (final 1), got #{final}"
    end

    test "atomic INCR under the identical schedule keeps both updates: register ends at 2" do
      final =
        run_race(
          fn _conn, _key -> nil end,
          fn conn, key, _v -> Redix.command!(conn, ["INCR", key]) end
        )

      assert final == "2",
             "atomic INCR must not lose an update (final 2), got #{final}"
    end
  end

  describe "atomic INCR branches are always linearizable (no false positive)" do
    for seed <- 1..10 do
      test "seed #{seed}: linearizable" do
        assert {:ok, _stats} =
                 PropertyDamage.run(
                   model: RedisBench.Model,
                   adapter: RedisBench.Adapter,
                   seed: unquote(seed),
                   max_commands: 12,
                   max_runs: 40,
                   verbose: false,
                   branching: @branching
                 )
      end
    end
  end

  describe "faithful GET-then-SET branches are linearizable (no false positive)" do
    for seed <- 1..8 do
      test "seed #{seed}: linearizable" do
        assert {:ok, _stats} =
                 PropertyDamage.run(
                   model: RedisBench.RmwModel,
                   adapter: RedisBench.Adapter,
                   seed: unquote(seed),
                   max_commands: 12,
                   max_runs: 40,
                   verbose: false,
                   branching: @branching
                 )
      end
    end
  end

  describe "racing GET-then-SET loses updates the linearization checker refutes" do
    for seed <- 1..8 do
      test "seed #{seed}: detected as a linearization failure" do
        assert {:error, failure} = run_lost_update(unquote(seed))

        assert %PropertyDamage.Failure{
                 type: %PropertyDamage.Failure.Assertion{kind: :linearization}
               } = failure.failure_reason,
               "expected a linearization failure, got #{inspect(failure.failure_reason)}"

        assert FailureReport.parallel_failure?(failure)
      end
    end

    test "shrinks to the minimal two-GetThenSet race" do
      # Seed 1 shrinks to exactly two GetThenSet (verified reproducibly); other
      # seeds also detect the race but may retain an incidental ReadValue.
      assert {:error, failure} = run_lost_update(1)

      commands = Sequence.to_list(FailureReport.shrunk_sequence(failure))

      assert [%GetThenSet{}, %GetThenSet{}] = commands,
             "expected the minimal two-write lost update, got: #{inspect(commands)}"

      assert %PropertyDamage.Failure{
               type: %PropertyDamage.Failure.Assertion{kind: :linearization}
             } = failure.failure_reason
    end

    test "the shrunk reproduction still fails" do
      assert {:error, failure} = run_lost_update(1)

      {:ok, replay} =
        PropertyDamage.Executor.run(
          FailureReport.shrunk_sequence(failure),
          RedisBench.RmwModel,
          LostUpdateAdapter,
          adapter_config: %{}
        )

      refute replay.success
    end

    test "shrinking is deterministic across repeated runs" do
      shrink = fn ->
        {:error, f} = run_lost_update(1)
        Sequence.to_list(FailureReport.shrunk_sequence(f))
      end

      assert shrink.() == shrink.()
    end
  end

  describe "checker: the lost update is refuted on write events alone" do
    test "two writes both observing from: 0 has no linearization" do
      branch_commands = [[%GetThenSet{}], [%GetThenSet{}]]

      # The race: both writes report from: 0. Whichever serializes second should
      # have observed from: 1, so no ordering explains this.
      branch_events = %{
        0 => [written_entry(0, 1, 0)],
        1 => [written_entry(0, 1, 0)]
      }

      assert {:no_linearization, nil} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 projections(),
                 RedisBench.RmwModel
               )
    end

    test "a healthy pair of writes is accepted" do
      branch_commands = [[%GetThenSet{}], [%GetThenSet{}]]

      branch_events = %{
        0 => [written_entry(0, 1, 0)],
        1 => [written_entry(1, 2, 0)]
      }

      assert {:ok, _ordering} =
               Linearization.check(
                 branch_commands,
                 branch_events,
                 projections(),
                 RedisBench.RmwModel
               )
    end
  end

  defp run_lost_update(seed) do
    PropertyDamage.run(
      model: RedisBench.RmwModel,
      adapter: LostUpdateAdapter,
      seed: seed,
      max_commands: 12,
      max_runs: 40,
      verbose: false,
      branching: @branching
    )
  end

  # Drive a genuine two-connection race with a barrier that releases the writes
  # only after BOTH reads have completed, so the interleaving is reliable rather
  # than timing-dependent. Returns the register's final value as a string.
  defp run_race(read_fun, write_fun) do
    key = Conn.run_key()
    {:ok, c1} = Conn.start_direct()
    {:ok, c2} = Conn.start_direct()
    {:ok, _} = Redix.command(c1, ["SET", key, "0"])
    {:ok, gate} = Agent.start_link(fn -> 0 end)

    worker = fn conn ->
      fn ->
        value = read_fun.(conn, key)
        Agent.update(gate, &(&1 + 1))
        await_gate(gate, 2)
        write_fun.(conn, key, value)
      end
    end

    [c1, c2]
    |> Enum.map(&Task.async(worker.(&1)))
    |> Enum.each(&Task.await/1)

    {:ok, final} = Redix.command(c1, ["GET", key])
    Redix.stop(c1)
    Redix.stop(c2)
    Agent.stop(gate)
    final
  end

  defp await_gate(gate, needed) do
    if Agent.get(gate, & &1) >= needed do
      :ok
    else
      Process.sleep(1)
      await_gate(gate, needed)
    end
  end

  defp projections, do: %{RedisBench.Projection => RedisBench.Projection.init()}

  defp written_entry(from, to, command_index) do
    Entry.from_command(%Written{from: from, to: to}, command_index, timestamp: 1)
  end

  defp to_int(nil), do: 0
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
end
