defmodule PropertyDamage.AnalysisTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Analysis
  alias PropertyDamage.Failure
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Placeholder
  alias PropertyDamage.PlaceholderRegistry
  alias PropertyDamage.Sequence
  alias PropertyDamage.Sequence.Position

  defmodule Alpha, do: defstruct(id: nil)
  defmodule Beta, do: defstruct(id: nil)
  defmodule Gamma, do: defstruct(id: nil)
  defmodule Delta, do: defstruct(id: nil)

  # A producing event whose external field is `:id`, and command structs that
  # can carry a consumed placeholder in `:ref`.
  defmodule Event, do: defstruct(id: nil)
  defmodule Producer, do: defstruct(id: nil)
  defmodule Decoy, do: defstruct(id: nil)
  defmodule Consumer, do: defstruct(ref: nil)

  describe "explain/1 branch-aware trigger localization" do
    # prefix [Alpha] ++ branches [[Beta], [Gamma]] ++ suffix [Delta].
    # Flattened order: Alpha=0, Beta=1, Gamma=2, Delta=3. The executor numbers
    # both branch commands from prefix_len (=1), so a branch-1 failure records
    # failed_at_index: 1 (branch_id: 1) whose FLATTENED index is 2. Keying the
    # dependency graph by the executor index would mislabel Beta as the trigger.
    setup do
      seq = Sequence.branching([%Alpha{}], [[%Beta{}], [%Gamma{}]], [%Delta{}])

      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: seq,
          shrunk_sequence: seq,
          failed_at_index: 1,
          failure_reason: Failure.in_branch(Failure.assertion_failed(:TestCheck, "boom"), 1)
        )

      %{report: report}
    end

    test "reports the flattened index of the failing command", %{report: report} do
      explanation = Analysis.explain(report)
      assert explanation.failure.command_index == 2
    end

    test "labels the branch-1 command (Gamma) as the trigger, not the index collision",
         %{report: report} do
      explanation = Analysis.explain(report)
      trigger = Enum.find(explanation.commands, &(&1.role == :trigger))

      assert trigger.index == 2
      assert trigger.command_name == "Gamma"

      beta = Enum.find(explanation.commands, &(&1.command_name == "Beta"))
      refute beta.role == :trigger
    end
  end

  describe "explain/1 over a shrunk sequence with a remapped registry" do
    # The shrinker deliberately leaves each surviving command's embedded
    # %Placeholder{} position at its stale original offset and instead remaps
    # the registry's producer_link onto the new positions (see
    # PlaceholderRegistry.remap_positions/2). explain/1 must derive producer
    # node indices from that registry, not the stale embedded positions, so the
    # dependency graph indexes into the shrunk command list correctly.

    test "regression: a stale embedded position beyond the command list no longer crashes" do
      # Consumer embeds a placeholder whose embedded position (prefix offset 7)
      # points past the end of the 2-command shrunk list. The registry, after
      # the shrinker's remap, maps the CURRENT producer position (prefix 0) to
      # that placeholder's id. Pre-fix this crashed with KeyError on nil at
      # analysis.ex build_dependency_chain (Enum.at past the end -> nil).
      stale_ph = Placeholder.new_at(Event, [:id], Position.prefix(7), 0)

      registry =
        [%Consumer{ref: stale_ph}]
        |> PlaceholderRegistry.build()
        |> PlaceholderRegistry.remap_positions(%{Position.prefix(7) => Position.prefix(0)})

      seq =
        [%Producer{}, %Consumer{ref: stale_ph}]
        |> Sequence.linear()
        |> Sequence.with_registry(registry)

      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: seq,
          shrunk_sequence: seq,
          failed_at_index: 1,
          failure_reason: Failure.assertion_failed(:TestCheck, "boom")
        )

      explanation = Analysis.explain(report)

      # The producer is named at its CURRENT index (0), and the failing consumer
      # at index 1; the chain runs producer -> consumer.
      assert explanation.dependency_chain == ["[0] Producer", "[1] Consumer"]

      producer = Enum.find(explanation.commands, &(&1.command_name == "Producer"))
      consumer = Enum.find(explanation.commands, &(&1.command_name == "Consumer"))

      assert producer.index == 0
      assert producer.role == :dependency
      assert consumer.index == 1
      assert consumer.role == :trigger
    end

    test "stale-but-in-range embedded position: the chain follows the registry, not the embed" do
      # The embedded placeholder position (prefix 1) points at a DIFFERENT
      # surviving command (Decoy at index 1), while the remapped registry maps
      # the real producer position (prefix 0, Producer) to the id. A stale
      # in-range position would not crash but would silently attribute the
      # dependency to the wrong command; the fix must follow the registry.
      ph = Placeholder.new_at(Event, [:id], Position.prefix(1), 0)

      registry =
        [%Consumer{ref: ph}]
        |> PlaceholderRegistry.build()
        |> PlaceholderRegistry.remap_positions(%{Position.prefix(1) => Position.prefix(0)})

      seq =
        [%Producer{}, %Decoy{}, %Consumer{ref: ph}]
        |> Sequence.linear()
        |> Sequence.with_registry(registry)

      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: seq,
          shrunk_sequence: seq,
          failed_at_index: 2,
          failure_reason: Failure.assertion_failed(:TestCheck, "boom")
        )

      explanation = Analysis.explain(report)

      # Producer (index 0) is the dependency, not Decoy (the stale-embed target).
      assert explanation.dependency_chain == ["[0] Producer", "[2] Consumer"]

      producer = Enum.find(explanation.commands, &(&1.command_name == "Producer"))
      decoy = Enum.find(explanation.commands, &(&1.command_name == "Decoy"))

      assert producer.role == :dependency
      refute decoy.role == :dependency
    end

    test "non-localized failure (failed_at_index nil) returns without raising and empty chain" do
      # A whole-run failure (e.g. a linearization check) localizes to no command,
      # so failed_at_index is nil. explain/1 must not call Enum.at(commands, nil).
      seq = Sequence.linear([%Alpha{}, %Beta{}])

      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: seq,
          shrunk_sequence: seq,
          failed_at_index: nil,
          failure_reason: Failure.linearization("branches did not linearize")
        )

      explanation = Analysis.explain(report)

      assert explanation.dependency_chain == []
      assert explanation.failure.command_index == nil
    end
  end
end
