defmodule PropertyDamage.Model.Projection.StatisticsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model.Projection.Statistics

  describe "init/1" do
    test "reads thresholds from the checks: option" do
      checks = [{:error_rate, :less_than, 0.05}]

      assert %Statistics{checks: ^checks} = Statistics.init(checks: checks)
    end

    test "rejects the retired assertions: option" do
      error =
        assert_raise ArgumentError, fn ->
          Statistics.init(assertions: [{:error_rate, :less_than, 0.05}])
        end

      assert error.message == "`assertions:` was renamed `checks:`"
    end
  end
end
