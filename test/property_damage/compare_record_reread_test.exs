defmodule PropertyDamage.CompareRecordRereadTest do
  # Under `check_mode: :record` a failing check does not stop a variant, so a
  # check that fails on a re-read of a probe last root must not stop that
  # variant's re-reads either: every variant keeps re-reading the root at the
  # final boundary until the sides agree or the convergence bound expires,
  # and the recorded failure is still the run's failure.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Failure, Scheduler, Target}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{Balance, Pay, PayAdapter, Read}

  defmodule Checked do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{balance: nil, fresh: true}

    @impl true
    def apply(state, %Balance{value: value, fresh: fresh}),
      do: %{state | balance: value, fresh: fresh}

    def apply(state, _event), do: state

    @compare every: Read
    def balance(state, _root),
      do: if(state.fresh, do: state.balance, else: {:pending, :stale_read})

    @check every: Balance
    def assert_sane_balance(_state, %Balance{value: value}) do
      if value == 99, do: PropertyDamage.fail!("balance 99 is never valid", value: value)
      :ok
    end
  end

  defmodule PayThenRead do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: Compare.commands([Pay, Read])

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter

    @impl true
    def check_projections, do: [PropertyDamage.CompareRecordRereadTest.Checked]
  end

  defp target(index, name, reads) do
    %Target{
      adapter: PayAdapter,
      name: name,
      index: index,
      config: %{name: name, test_pid: self(), reads: reads}
    }
  end

  for concurrency <- [:serial, :parallel] do
    test "a check failing on the first final re-read does not stop that variant's re-reads (#{concurrency})" do
      stale = {0, false}

      # Both sides read stale four times, then the fresh balance. The
      # variant's second read (its first re-read at the final boundary)
      # answers the value the check rejects.
      targets = [
        target(0, "a", [stale, stale, stale, stale, {10, true}]),
        target(1, "b", [stale, {99, false}, stale, stale, {10, true}])
      ]

      {:ok, run} =
        Scheduler.run(
          model: PayThenRead,
          targets: targets,
          commands: [%Pay{n: 0, amount: 3}, %Read{n: 1}],
          seed: 1,
          run_number: 0,
          run_nonce: 1,
          concurrency: unquote(concurrency),
          check_mode: :record,
          compare: [converge_within: 2_000]
        )

      # Every variant re-read until both read the fresh balance.
      executions = Compare.executions()
      reads = {Compare.count(executions, "a", 1, Read), Compare.count(executions, "b", 1, Read)}
      assert reads == {5, 5}

      # The sides agreed; the recorded check failure is the run's failure.
      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, root: 1} = run.failure
      assert Failure.name(run.failure.reason) == :sane_balance
      assert run.other_failures == []

      [reference, variant] = run.results
      assert reference.success
      refute variant.success
      assert [%{command_index: 1}] = variant.check_failures
      assert variant.projections[Checked] == %{balance: 10, fresh: true}
    end
  end
end
