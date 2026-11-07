defmodule RedisBenchTest do
  @moduledoc """
  Baseline: the register stays consistent against real Redis.

  `INCR` is atomic, so a faithful adapter must never violate the read-consistency
  invariant.
  """
  use ExUnit.Case, async: false

  test "register reads stay consistent against real Redis (linear)" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: RedisBench.Model,
               targets: [RedisBench.Adapter],
               max_commands: 30,
               max_runs: 50,
               verbose: false
             )
  end
end
