defmodule PropertyDamage.Shrinker.ConfigTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Shrinker.Config

  describe "new/0" do
    test "returns struct with defaults" do
      config = Config.new()

      assert config.granularity_threshold == 8
      assert config.max_iterations == 1000
      assert config.max_time_ms == 30_000
      assert config.shrink_arguments == true
    end
  end

  describe "new/1" do
    test "accepts custom granularity_threshold" do
      config = Config.new(granularity_threshold: 4)

      assert config.granularity_threshold == 4
    end

    test "accepts custom max_iterations" do
      config = Config.new(max_iterations: 500)

      assert config.max_iterations == 500
    end

    test "accepts custom max_time_ms" do
      config = Config.new(max_time_ms: 10_000)

      assert config.max_time_ms == 10_000
    end

    test "accepts custom shrink_arguments" do
      config = Config.new(shrink_arguments: false)

      assert config.shrink_arguments == false
    end

    test "accepts multiple options" do
      config =
        Config.new(
          granularity_threshold: 2,
          max_iterations: 100,
          max_time_ms: 5_000,
          shrink_arguments: false
        )

      assert config.granularity_threshold == 2
      assert config.max_iterations == 100
      assert config.max_time_ms == 5_000
      assert config.shrink_arguments == false
    end

    test "raises on invalid key" do
      assert_raise KeyError, fn ->
        Config.new(invalid_key: true)
      end
    end
  end

  describe "struct" do
    test "can be created directly" do
      config = %Config{
        granularity_threshold: 16,
        max_iterations: 2000
      }

      assert config.granularity_threshold == 16
      assert config.max_iterations == 2000
      # Defaults still apply for unset fields
      assert config.max_time_ms == 30_000
      assert config.shrink_arguments == true
    end
  end
end
