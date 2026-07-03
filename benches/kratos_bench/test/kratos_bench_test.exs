defmodule KratosBenchTest do
  @moduledoc """
  The headline demonstration: PropertyDamage's mock is the third party a real Ory
  Kratos calls during registration, and that mock's answer steers Kratos state.

  With the mock behaving, every invariant holds across generated sequences that
  mix accepted / rejected / modified registrations, logins, listings and deletes.
  The coverage assertion proves the `when:`-gated commands (`Login`,
  `DeleteIdentity`) were actually generated — i.e. the simulator populated the
  projection during the symbolic phase (the simulator trap).
  """

  use ExUnit.Case, async: false

  alias KratosBench.Commands.{DeleteIdentity, Login}

  @moduletag timeout: 600_000

  test "the mock steers Kratos and every invariant holds" do
    assert {:ok, stats} =
             PropertyDamage.run(
               model: KratosBench.Model,
               adapter: KratosBench.Adapter,
               adapter_config: KratosBench.adapter_config(),
               max_commands: 20,
               max_runs: 6,
               coverage: true
             )

    counts = stats.coverage.command_counts

    assert Map.get(counts, Login, 0) > 0,
           "expected the gated Login command to be generated and run, got #{inspect(counts)}"

    assert Map.get(counts, DeleteIdentity, 0) > 0,
           "expected the gated DeleteIdentity command to be generated and run, got #{inspect(counts)}"
  end
end
