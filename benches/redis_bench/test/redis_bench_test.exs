defmodule RedisBenchTest do
  @moduledoc """
  Baseline: the register is linearizable against real Redis with NO faults.

  `INCR` is atomic, so a faithful adapter must never violate the read-consistency
  invariant. This is the green-before-faults baseline; the fault-injection
  suites build on the same model.
  """
  use ExUnit.Case, async: false

  test "register reads stay consistent against real Redis (linear, no faults)" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: RedisBench.Model,
               adapter: RedisBench.Adapter,
               max_commands: 30,
               max_runs: 50,
               verbose: false
             )
  end
end
