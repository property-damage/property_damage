defmodule PropertyDamage.ProvenanceTest do
  @moduledoc "DR-034 §4: value provenance classification, derived structurally."
  use ExUnit.Case, async: true

  alias PropertyDamage.{Mint, Placeholder, Provenance, RunTrace, Sequence}

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, id: external()]
  end

  defmodule Send do
    defstruct [:request_id, :amount, :target]
  end

  describe "command_field/1" do
    test "mint marker is run-scoped, placeholder is server-resolved, else plan-generated" do
      assert Provenance.command_field(Mint.new(:uuid)) == :run_scoped
      assert Provenance.command_field(%Placeholder{}) == :server_resolved
      assert Provenance.command_field(42) == :plan_generated
      assert Provenance.command_field("literal") == :plan_generated
    end
  end

  describe "event_field/4" do
    test "an external() path is server-resolved by definition" do
      assert Provenance.event_field(Created, [:id], "anything", MapSet.new()) == :server_resolved
    end

    test "a value in the minted set is a run-scoped echo" do
      minted = MapSet.new(["req-123"])
      assert Provenance.event_field(Created, [:amount], "req-123", minted) == :run_scoped
    end

    test "other observed values are server-resolved" do
      assert Provenance.event_field(Created, [:amount], 999, MapSet.new()) == :server_resolved
    end
  end

  describe "mint_paths/1 and minted_value_set/1" do
    test "finds the field paths carrying mint markers" do
      command = %Send{
        request_id: Mint.reify(Mint.new(:uuid), {:prefix, 0}, [:request_id]),
        amount: 5,
        target: %Placeholder{}
      }

      assert Provenance.mint_paths(command) == [[:request_id]]
    end

    test "collects resolved minted values from a trace by correlating plan + executed" do
      marker = Mint.reify(Mint.new(:uuid), {:prefix, 0}, [:request_id])
      plan_command = %Send{request_id: marker, amount: 1}
      exec_command = %Send{request_id: "resolved-uuid", amount: 1}

      trace =
        RunTrace.new(
          plan: Sequence.linear([plan_command]),
          executed: %{%Sequence.Position{section: :prefix, offset: 0} => exec_command},
          outcome: :pass
        )

      assert Provenance.minted_value_set(trace) == MapSet.new(["resolved-uuid"])
    end

    test "empty when the plan has no mint markers" do
      trace = RunTrace.new(plan: Sequence.linear([%Send{amount: 1}]), outcome: :pass)
      assert Provenance.minted_value_set(trace) == MapSet.new()
    end
  end
end
