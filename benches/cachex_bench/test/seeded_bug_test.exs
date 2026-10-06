defmodule CachexBench.SeededBugTest do
  @moduledoc """
  Validates that the bench is not passing vacuously: a deliberately buggy
  adapter (delete silently does nothing) must be caught by the model's
  read-consistency invariant, and the failure must shrink to the minimal
  reproduction (a write -> del -> get on the same key: 3 commands; the write
  is a put or an increment).
  """
  use ExUnit.Case, async: false

  defmodule LyingAdapter do
    @moduledoc "Same as the real adapter, except DelKey silently no-ops."
    use PropertyDamage.Adapter

    alias CachexBench.Commands.DelKey
    alias CachexBench.Events.EntryDeleted

    @impl true
    def setup(config), do: CachexBench.Adapter.setup(config)

    @impl true
    def teardown(ctx), do: CachexBench.Adapter.teardown(ctx)

    @impl true
    def execute(%DelKey{key: key}, _ctx, _runtime) do
      # BUG: claims the entry was deleted but never touches the cache
      {:ok, [%EntryDeleted{key: key}]}
    end

    def execute(command, ctx, runtime),
      do: CachexBench.Adapter.execute(command, ctx, runtime)
  end

  test "the seeded delete bug is found and shrunk to a minimal reproduction" do
    result =
      PropertyDamage.run(
        model: CachexBench.Model,
        targets: [LyingAdapter],
        max_commands: 30,
        max_runs: 200,
        verbose: false
      )

    assert {:error, failure} = result
    # Note: PD strips the assert_ prefix from check names
    assert PropertyDamage.FailureReport.check_name(failure) == :read_consistent

    shrunk = PropertyDamage.FailureReport.shrunk_sequence(failure)
    commands = PropertyDamage.Sequence.to_list(shrunk)

    # Minimal repro is put -> del -> get on one key. Allow a little slack,
    # but anything beyond 5 commands means shrinking quality regressed.
    assert length(commands) <= 5,
           "expected a near-minimal reproduction, got #{length(commands)} commands: " <>
             inspect(commands)

    # The repro must end in a read, and contain a write and the del for its
    # key. A write is a put or an increment: an Incr of an absent key stores
    # its amount.
    %CachexBench.Commands.GetKey{key: key} = List.last(commands)

    assert Enum.any?(commands, fn
             %CachexBench.Commands.PutKey{key: ^key} -> true
             %CachexBench.Commands.Incr{key: ^key} -> true
             _other -> false
           end)

    assert Enum.any?(commands, &match?(%CachexBench.Commands.DelKey{key: ^key}, &1))
  end
end
