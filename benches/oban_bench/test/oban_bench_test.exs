defmodule ObanBenchTest do
  @moduledoc """
  The core eventual-consistency loop end to end against real Oban + Postgres:
  commands enqueue async jobs, resource pollers observe the database between
  commands, and the `@poll_state` invariant asserts the observed counter value
  eventually matches what was enqueued.
  """
  use ExUnit.Case, async: false

  test "increments are eventually consistent under real async Oban processing" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: ObanBench.Model,
               adapter: ObanBench.Adapter,
               max_commands: 20,
               max_runs: 25,
               verbose: false
             )
  end
end
