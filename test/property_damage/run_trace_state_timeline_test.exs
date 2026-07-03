defmodule PropertyDamage.RunTraceStateTimelineTest do
  @moduledoc """
  P8 / DR-040: unit-level contracts for the derived per-step state timeline,
  driven by hand-built traces so the fold-order and branch-merge semantics are
  pinned precisely (independent of any live run).
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{RunTrace, Sequence}
  alias PropertyDamage.Sequence.Position

  defmodule Cmd, do: defstruct([:op])
  defmodule Ev, do: defstruct([:tag])

  # Order-sensitive projection: records the tag/op of everything folded, in fold
  # order, so the derived state reveals exactly what was folded and when.
  defmodule Log do
    @moduledoc false
    use PropertyDamage.Model.Projection
    @impl true
    def init, do: %{log: []}
    @impl true
    def apply(state, %Ev{tag: tag}), do: %{state | log: state.log ++ [tag]}
    def apply(state, %Cmd{op: op}), do: %{state | log: state.log ++ [{:cmd, op}]}
    def apply(state, _), do: state
  end

  defmodule Model do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: Log
    @impl true
    def assertion_projections, do: []
  end

  describe "faithful timeline (linear)" do
    test "folds commands and events in recorded fold order, injected before command" do
      # Fold order for C0: an injected event (ordinal 0), then the command fold
      # (ordinal 1), then the command's own event (ordinal 2); then C1 (3) + its
      # event (4). This mirrors the executor: injected events fold before their
      # command.
      trace =
        RunTrace.new(
          model: Model,
          plan: Sequence.linear([%Cmd{op: :c0}, %Cmd{op: :c1}]),
          executed: %{
            Position.prefix(0) => %Cmd{op: :c0},
            Position.prefix(1) => %Cmd{op: :c1}
          },
          command_fold_ordinals: %{Position.prefix(0) => 1, Position.prefix(1) => 3},
          event_log: [
            %Entry{command_index: 1, event: %Ev{tag: :e1}, source: :command, fold_index: 4},
            %Entry{command_index: 0, event: %Ev{tag: :e0}, source: :command, fold_index: 2},
            %Entry{command_index: 0, event: %Ev{tag: :inj}, source: :injected, fold_index: 0}
          ],
          outcome: :pass
        )

      assert RunTrace.state_at(trace, Position.prefix(0))[Log] ==
               %{log: [:inj, {:cmd, :c0}, :e0]}

      assert RunTrace.state_before(trace, Position.prefix(0))[Log] == %{log: []}

      assert RunTrace.state_at(trace, Position.prefix(1))[Log] ==
               %{log: [:inj, {:cmd, :c0}, :e0, {:cmd, :c1}, :e1]}

      # Timeline is one entry per command, in reading order.
      assert Enum.map(RunTrace.state_timeline(trace), fn {_pos, s} -> s[Log].log end) == [
               [:inj, {:cmd, :c0}, :e0],
               [:inj, {:cmd, :c0}, :e0, {:cmd, :c1}, :e1]
             ]
    end
  end

  describe "faithful timeline (branching) recovers the verified linearization order" do
    test "the merged state folds branches in linearization order, not branch order" do
      plan =
        Sequence.branching([], [[%Cmd{op: :a}], [%Cmd{op: :b}]], [%Cmd{op: :sink}])

      b0 = Position.branch(0, 0)
      b1 = Position.branch(1, 0)
      sfx = Position.suffix(0)

      # Verified order is branch 1 THEN branch 0 -- the reverse of branch order.
      trace =
        RunTrace.new(
          model: Model,
          plan: plan,
          executed: %{b0 => %Cmd{op: :a}, b1 => %Cmd{op: :b}, sfx => %Cmd{op: :sink}},
          command_fold_ordinals: %{b0 => 0, b1 => 0, sfx => 1},
          linearization: [{1, 0, %Cmd{op: :b}}, {0, 0, %Cmd{op: :a}}],
          event_log: [],
          outcome: :pass
        )

      assert RunTrace.state_at(trace, sfx)[Log] == %{log: [{:cmd, :b}, {:cmd, :a}, {:cmd, :sink}]}

      # state_before the suffix is the merged state with no suffix folds yet.
      assert RunTrace.state_before(trace, sfx)[Log] == %{log: [{:cmd, :b}, {:cmd, :a}]}
    end

    test "falls back to branch order when no linearization was verified" do
      plan =
        Sequence.branching([], [[%Cmd{op: :a}], [%Cmd{op: :b}]], [%Cmd{op: :sink}])

      trace =
        RunTrace.new(
          model: Model,
          plan: plan,
          executed: %{
            Position.branch(0, 0) => %Cmd{op: :a},
            Position.branch(1, 0) => %Cmd{op: :b},
            Position.suffix(0) => %Cmd{op: :sink}
          },
          command_fold_ordinals: %{
            Position.branch(0, 0) => 0,
            Position.branch(1, 0) => 0,
            Position.suffix(0) => 1
          },
          linearization: nil,
          event_log: [],
          outcome: :pass
        )

      assert RunTrace.state_at(trace, Position.suffix(0))[Log] ==
               %{log: [{:cmd, :a}, {:cmd, :b}, {:cmd, :sink}]}
    end
  end
end
