defmodule KratosBenchTest do
  @moduledoc """
  The headline demonstration: PropertyDamage's mock is the third party a real Ory
  Kratos calls during registration, and that mock's answer steers Kratos state.

  With the mock behaving, every invariant holds across generated sequences that
  mix accepted / rejected / modified registrations, logins, listings and deletes.
  The coverage check proves the `when:`-gated commands (`Login`,
  `DeleteIdentity`) were actually generated — i.e. the simulator populated the
  projection during the symbolic phase (the simulator trap).
  """

  use ExUnit.Case, async: false

  alias KratosBench.Commands.{DeleteIdentity, Login}

  @moduletag timeout: 600_000

  # A seed whose six runs draw both gated commands, checked against the
  # symbolic phase alone (no Kratos needed), so the coverage assertions
  # below do not depend on a lucky draw.
  @seed 5

  test "the mock steers Kratos and every invariant holds" do
    assert {:ok, stats} =
             PropertyDamage.run(
               model: KratosBench.Model,
               targets: [{KratosBench.Adapter, config: KratosBench.target_config()}],
               max_commands: 20,
               max_runs: 6,
               seed: @seed,
               coverage: true
             )

    counts = stats.coverage.command_counts

    assert Map.get(counts, Login, 0) > 0,
           "expected the gated Login command to be generated and run, got #{inspect(counts)} (seed #{@seed})"

    assert Map.get(counts, DeleteIdentity, 0) > 0,
           "expected the gated DeleteIdentity command to be generated and run, got #{inspect(counts)} (seed #{@seed})"
  end
end
