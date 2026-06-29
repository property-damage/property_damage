defmodule PropertyDamage.Executor.StateTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Executor.State

  # DR-029: these tests pin the run-state contract so later strangler extractions
  # cannot silently change it. Replay reads exec_state.event_log and
  # exec_state.projections (replay.ex); the finalize chain and branching read the
  # rest. A rename/removal must break here, loudly.

  @consumed_fields [
    # Replay's two reads (the externally de-facto frozen names)
    :event_log,
    :projections,
    # finalize chain / per-command engine / branching
    :projections_before,
    :assertion_counters,
    :assertion_failures,
    :assertion_mode,
    :active_pollers,
    :active_resource_pollers,
    :active_faults,
    :async_halt,
    :branch_id,
    :current_position,
    :step_count,
    :placeholder_registry,
    :command_specs,
    :stutter_config,
    :mock_registry,
    :external_markers,
    :event_queue,
    :model
  ]

  defp minimal_state do
    %State{
      model: __MODULE__.NoModel,
      event_queue: nil,
      assertion_mode: :halt,
      stutter_config: nil,
      mock_registry: nil,
      external_markers: [],
      command_specs: %{},
      placeholder_registry: nil
    }
  end

  test "declares every field Replay, finalize, and branching consume" do
    fields = State.__struct__() |> Map.from_struct() |> Map.keys() |> MapSet.new()

    for f <- @consumed_fields do
      assert f in fields,
             "Executor.State must declare #{inspect(f)} (consumed by Replay/finalize/branching)"
    end
  end

  test "the ghost fields default sanely (active_faults => %{}, async_halt => nil)" do
    state = minimal_state()
    assert state.active_faults == %{}
    assert state.async_halt == nil
  end

  test "a write to an undeclared field raises (struct!/2 enforcement, DR-029)" do
    state = minimal_state()
    # This is exactly what put_state/2 now does; an undeclared key must raise
    # rather than silently corrupt the struct (Map.merge/2 would not).
    assert_raise KeyError, fn -> struct!(state, %{not_a_real_field: 1}) end
  end

  test "construction enforces the always-present configuration keys" do
    assert_raise ArgumentError, fn ->
      # missing every @enforce_keys field
      struct!(State, %{})
    end
  end
end
