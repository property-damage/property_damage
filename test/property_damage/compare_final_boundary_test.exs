defmodule PropertyDamage.CompareFinalBoundaryTest do
  # The final boundary is a boundary like any other: when the last root is a
  # probe (`execution: :probe`), each iteration of the convergence loop
  # re-executes it in every variant, the reference included, after the
  # variants finalized their runs. Finalizing stops a variant's pollers, not
  # the system under test, so a later read can still see newer state.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Failure, Scheduler, Target}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{Balance, Pay, PayAdapter, Read}

  defmodule Balances do
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
  end

  defmodule PayThenRead do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: Compare.commands([Pay, Read])

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.Compare.Counter

    @impl true
    def check_projections, do: [PropertyDamage.CompareFinalBoundaryTest.Balances]
  end

  # "b" reads a stale balance twice before the fresh one.
  defp stale_twice, do: %{reads: [{0, false}, {0, false}, {10, true}]}

  defp target(index, name, config \\ %{}) do
    %Target{
      adapter: PayAdapter,
      name: name,
      index: index,
      config: Map.merge(%{name: name, test_pid: self()}, config)
    }
  end

  defp scheduler_run(targets, concurrency) do
    {:ok, run} =
      Scheduler.run(
        model: PayThenRead,
        targets: targets,
        commands: [%Pay{n: 0, amount: 3}, %Read{n: 1}],
        seed: 1,
        run_number: 0,
        run_nonce: 1,
        concurrency: concurrency,
        compare: [converge_within: 300]
      )

    run
  end

  defp balances(result) do
    for %{command_index: 1, event: %Balance{} = event} <- result.event_log,
        do: {event.value, event.fresh}
  end

  test "a probe last root whose first read is stale converges at the end boundary" do
    targets = [Compare.target("a"), Compare.target("b", stale_twice())]

    assert {:ok, _stats} =
             Compare.run(PayThenRead, targets,
               max_commands: 2,
               compare: [converge_within: 300]
             )
  end

  for concurrency <- [:serial, :parallel] do
    test "every variant re-executes the probe last root once per iteration (#{concurrency})" do
      run = scheduler_run([target(0, "a"), target(1, "b", stale_twice())], unquote(concurrency))

      assert run.failure == nil

      # The first read, then one re-read in each of the two iterations "b"
      # needed to read fresh data; the reference is re-read alongside.
      executions = Compare.executions()
      assert Compare.count(executions, "a", 1, Read) == 3
      assert Compare.count(executions, "b", 1, Read) == 3

      # The re-reads' events are in each variant's final event log, after the
      # stale reads, which stay.
      [reference, variant] = run.results
      assert balances(reference) == [{10, true}, {10, true}, {10, true}]
      assert balances(variant) == [{0, false}, {0, false}, {10, true}]
    end
  end

  test "control: a probe last root that never reads fresh data does not converge" do
    targets = [Compare.target("a"), Compare.target("b", %{reads: [{0, false}]})]

    {elapsed, result} =
      Compare.timed(fn ->
        Compare.run(PayThenRead, targets, max_commands: 2, compare: [converge_within: 150])
      end)

    assert {:error, report} = result
    assert report.kind == :did_not_converge
    assert report.variant == %{index: 1, name: "b"}
    assert report.failed_at_index == 1
    assert Failure.name(report.failure_reason) == {Balances, :balance}
    assert Map.fetch!(report.failure_reason.type, :waited_ms) >= 150
    assert elapsed >= 150
  end
end
