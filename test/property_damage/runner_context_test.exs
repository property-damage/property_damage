defmodule PropertyDamage.RunnerContextTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Runner
  alias PropertyDamage.Test.Gauntlet, as: G
  alias PropertyDamage.Test.RunnerSupport

  test "a context without a seed is refused with a message that names the seed" do
    context = %Runner.Context{
      model: G.Model,
      targets: RunnerSupport.targets([{G.Adapter, config: %{bug: :off}}])
    }

    error = assert_raise ArgumentError, fn -> Runner.execute(%{commands: []}, context) end

    assert error.message =~ "seed"
  end
end
