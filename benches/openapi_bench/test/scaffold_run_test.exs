defmodule OpenapiBench.ScaffoldRunTest do
  @moduledoc """
  The core 6e proof: the code emitted by `mix pd.scaffold` (commands + adapter,
  unmodified beyond the documented events/3 fill-in) drives the real HTTP API
  and the read-consistency invariant holds against the faithful SUT across
  seeds. This is the green-before-the-seeded-bug baseline.
  """
  use ExUnit.Case, async: false

  alias OpenapiBench.Generated.{Adapter, Model}
  alias OpenapiBench.Server

  @moduletag timeout: 120_000

  for seed <- 1..5 do
    test "generated client keeps the register consistent (faithful SUT, seed #{seed})" do
      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: Model,
                 adapter: Adapter,
                 adapter_config: %{base_url: Server.base_url(), bug: false},
                 max_commands: 25,
                 max_runs: 50,
                 seed: unquote(seed),
                 verbose: false
               )
    end
  end
end
