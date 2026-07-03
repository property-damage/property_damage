defmodule RedisBench.SeededBugTest do
  @moduledoc """
  Non-vacuity: a deliberately broken adapter is caught and shrunk to the
  minimal repro, proving the baseline's green is meaningful and not vacuous.

  The `StaleReadAdapter` increments faithfully but every `GET` returns the
  register's value as it was at connection time (0), never re-reading. So the
  first read after any increment observes a stale 0 while the model expects a
  higher count: a read-consistency violation that must shrink to the minimal
  `Increment -> ReadValue` pair.
  """
  use ExUnit.Case, async: false

  alias RedisBench.Commands.{Increment, ReadValue}

  defmodule StaleReadAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    alias RedisBench.Commands.{Increment, ReadValue}
    alias RedisBench.Conn
    alias RedisBench.Events.{Incremented, ValueRead}

    @impl true
    def setup(_config) do
      {:ok, conn} = Conn.start_direct()
      {:ok, %{conn: conn, key: Conn.run_key()}}
    end

    @impl true
    def teardown(%{conn: conn}) do
      Redix.stop(conn)
      :ok
    end

    @impl true
    def execute(%Increment{}, %{conn: conn, key: key}, _runtime) do
      {:ok, to} = Redix.command(conn, ["INCR", key])
      {:ok, [%Incremented{from: to - 1, to: to}]}
    end

    # The lie: never actually read the register, always report the initial 0.
    def execute(%ReadValue{}, _ctx, _runtime) do
      {:ok, [%ValueRead{value: 0}]}
    end
  end

  test "stale-read adapter is caught and shrinks to Increment -> ReadValue" do
    assert {:error, report} =
             PropertyDamage.run(
               model: RedisBench.Model,
               adapter: StaleReadAdapter,
               max_commands: 30,
               max_runs: 50,
               seed: 1,
               verbose: false
             )

    shrunk = PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))

    assert [%Increment{}, %ReadValue{}] = shrunk,
           "expected minimal Increment -> ReadValue, got #{inspect(shrunk)}"
  end
end
