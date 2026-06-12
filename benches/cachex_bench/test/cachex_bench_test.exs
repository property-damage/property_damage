defmodule CachexBenchTest do
  use ExUnit.Case, async: false
  use PropertyDamage.ExUnit

  property_damage("Cachex put/get/del/clear behaves like its model",
    model: CachexBench.Model,
    adapter: CachexBench.Adapter,
    max_commands: 30,
    max_runs: 150
  )
end
