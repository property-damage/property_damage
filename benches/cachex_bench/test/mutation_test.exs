defmodule CachexBench.MutationTest do
  @moduledoc """
  Exercises `PropertyDamage.Mutation` (WIP-tier) against the real Cachex SUT.

  Mutation testing perturbs the events the adapter returns and checks whether
  the model's invariants catch (kill) the perturbation. A killed mutant means
  the suite detected the injected fault; a surviving mutant means it slipped
  past. This bench is the promotion vehicle for the Mutation feature: it proves

    1. killing is genuinely driven by the read-consistency invariant (a
       structurally identical model with the invariant removed lets EVERY mutant
       survive), and
    2. the `PropertyDamage.Mutation.Report` shape is honest (totals reconcile,
       the score equals killed/total, breakdowns are keyed by real command
       modules, and killed details carry the invariant's failure message).
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Mutation
  alias PropertyDamage.Mutation.Report

  @moduletag timeout: 120_000

  @commands [
    CachexBench.Commands.PutKey,
    CachexBench.Commands.GetKey,
    CachexBench.Commands.DelKey,
    CachexBench.Commands.ClearCache
  ]

  # Kept CI-sane while leaving enough runs per mutation that a perturbed read is
  # reliably observed and caught. `:status`/`:event` operators are excluded on
  # purpose: they can replace the whole event list with an error tuple, which is
  # a different (transport-shaped) fault than the value/field perturbations this
  # bench is about.
  @operators [:value, :boundary, :omission]
  @opts [operators: @operators, mutations_per_command: 3, max_runs: 20]

  # Same commands, adapter, and projection apply-logic as CachexBench.Projection,
  # but with NO `@trigger` assertion. This is the control that isolates the
  # read-consistency invariant as the thing actually doing the killing.
  defmodule UncheckedProjection do
    use PropertyDamage.Model.Projection

    alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryPut, EntryRead}

    @impl true
    def init, do: %{expected: %{}, last_read: nil}

    @impl true
    def apply(state, %EntryPut{key: key, value: value}),
      do: put_in(state, [:expected, key], value)

    def apply(state, %EntryDeleted{key: key}),
      do: update_in(state, [:expected], &Map.delete(&1, key))

    def apply(state, %CacheCleared{}), do: %{state | expected: %{}}
    def apply(state, %EntryRead{key: key, value: value}), do: %{state | last_read: {key, value}}
    def apply(state, _event), do: state
  end

  defmodule UncheckedModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: CachexBench.Model.commands()

    @impl true
    def command_sequence_projection, do: CachexBench.MutationTest.UncheckedProjection

    @impl true
    def assertion_projections, do: []

    @impl true
    def simulator, do: CachexBench.Simulator
  end

  test "the read-consistency invariant kills mutants and the report shape is honest" do
    assert {:ok, report} =
             Mutation.run([model: CachexBench.Model, adapter: CachexBench.Adapter] ++ @opts)

    assert %Report{} = report

    # Mutations were actually generated and tested against a passing model.
    assert report.total > 0

    # The invariant catches perturbed reads: some mutants are killed.
    assert report.killed > 0
    assert report.mutation_score > 0.0

    # At least one mutant survives (a perturbation no GET observed), proving the
    # report records survivors too, not only kills.
    assert report.survived > 0

    # Honest arithmetic: totals reconcile and the score is exactly killed/total.
    assert report.total == report.killed + report.survived + report.timeout
    assert_in_delta report.mutation_score, report.killed / report.total, 1.0e-9

    # Breakdowns are keyed by the real command MODULES (the earlier bug keyed
    # them by option lists like `[weight: 5]`). Keys are a subset of the model's
    # commands and at least one command was exercised.
    command_keys = Map.keys(report.by_command)
    assert command_keys != []
    assert Enum.all?(command_keys, &is_atom/1)
    assert MapSet.subset?(MapSet.new(command_keys), MapSet.new(@commands))

    # Operator breakdown is keyed by the operators we asked for.
    operator_keys = Map.keys(report.by_operator)
    assert operator_keys != []
    assert MapSet.subset?(MapSet.new(operator_keys), MapSet.new(@operators))

    # Killed-mutation details are recorded 1:1 with the kill count and carry the
    # invariant's failure message.
    assert length(report.killed_mutations) == report.killed
    assert Enum.any?(report.killed_mutations, &is_binary(&1.failure_message))
  end

  test "without the invariant the same mutations all survive (control)" do
    assert {:ok, report} =
             Mutation.run([model: UncheckedModel, adapter: CachexBench.Adapter] ++ @opts)

    # Nothing checks the perturbed events, so no mutant can be killed. This is
    # the RED control proving the kills above are the invariant's doing, not an
    # artifact of the mutation machinery.
    assert report.total > 0
    assert report.killed == 0
    assert report.mutation_score == 0.0
    assert report.survived == report.total
  end
end
