defmodule PropertyDamage.RunComparisonStateTest do
  @moduledoc """
  P8 / DR-040: projection-state divergence enters RunComparison's field-divergence
  ranking using CANONICAL (timing-immune) states.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{RunComparison, RunTrace, Sequence}
  alias PropertyDamage.RunComparison.Field
  alias PropertyDamage.Sequence.Position

  defmodule C, do: defstruct([])
  defmodule E, do: defstruct([:v])

  defmodule SumP do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{total: 0}
    @impl true
    def apply(state, %E{v: v}), do: %{state | total: state.total + v}
    def apply(state, _), do: state
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [C]
    @impl true
    def command_sequence_projection, do: SumP
    @impl true
    def assertion_projections, do: []
  end

  defp trace(v, outcome) do
    RunTrace.new(
      plan: Sequence.linear([%C{}]),
      model: Model,
      seed: 1,
      run_number: 0,
      command_fold_ordinals: %{Position.prefix(0) => 0},
      event_log: [%Entry{command_index: 0, event: %E{v: v}, source: :command, fold_index: 1}],
      outcome: outcome
    )
  end

  test "a state-only divergence produces a ranked, classified :state finding" do
    passing = trace(1, :pass)
    failing = trace(2, {:fail, {:check_failed, :Inv, "boom"}})

    comparison = RunComparison.compare([passing, failing])
    assert comparison.comparable?

    state_ranked =
      Enum.filter(comparison.ranking, fn %Field{location: loc} ->
        match?({:state, _, _, _}, loc)
      end)

    assert [%Field{} = field] = state_ranked
    assert {:state, %Position{section: :prefix, offset: 0}, SumP, [:total]} = field.location
    assert field.classification == :discriminating
    assert field.provenance == :server_resolved
    assert field.values == %{0 => 1, 1 => 2}
  end

  test "state varying within one outcome group raises a non-pure-projection advisory" do
    # Two passing runs of the same plan whose derived state differs => same plan,
    # same outcome, different state: a likely non-pure projection.
    comparison = RunComparison.compare([trace(1, :pass), trace(2, :pass)])

    assert SumP in comparison.state_warnings
  end
end
