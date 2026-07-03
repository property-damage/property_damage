defmodule PropertyDamage.StutterTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Stutter
  alias PropertyDamage.Stutter.Config

  defmodule Cmd do
    defstruct []
  end

  # A fresh, fixed-seed RNG state for the policy draws (DR-029): the draw
  # functions take and return an explicit `:rand` state rather than reading the
  # process-global RNG.
  defp rng, do: :rand.seed_s(:exsss, 42)

  describe "should_stutter?/3" do
    test "returns false when the config is disabled" do
      config = %Config{
        probability: 1.0,
        max_repeats: 2,
        delay_ms: {0, 0},
        commands: :all,
        comparison: :strict,
        enabled: false
      }

      assert {false, _rng} = Stutter.should_stutter?(%Cmd{}, config, rng())
    end

    test "stutters when enabled with probability 1.0" do
      config = %Config{
        probability: 1.0,
        max_repeats: 2,
        delay_ms: {0, 0},
        commands: :all,
        comparison: :strict,
        enabled: true
      }

      assert {true, _rng} = Stutter.should_stutter?(%Cmd{}, config, rng())
    end

    test "is self-consistent: the same RNG state yields the same decision" do
      config = %Config{
        probability: 0.5,
        max_repeats: 2,
        delay_ms: {0, 0},
        commands: :all,
        comparison: :strict,
        enabled: true
      }

      {a, _} = Stutter.should_stutter?(%Cmd{}, config, rng())
      {b, _} = Stutter.should_stutter?(%Cmd{}, config, rng())
      assert a == b
    end
  end

  describe "retry_delay_ms/2" do
    test "returns a delay within the configured range" do
      config = %Config{delay_ms: {10, 20}}
      {delay, _rng} = Stutter.retry_delay_ms(config, rng())
      assert delay >= 10 and delay <= 20
    end

    test "does not raise on an inverted {max < min} delay tuple" do
      config = %Config{delay_ms: {100, 0}}
      {delay, _rng} = Stutter.retry_delay_ms(config, rng())
      assert delay >= 0 and delay <= 100
    end
  end

  describe "retry_count/2" do
    test "returns a count between 1 and max_repeats" do
      config = %Config{max_repeats: 3}
      {count, _rng} = Stutter.retry_count(config, rng())
      assert count >= 1 and count <= 3
    end
  end

  describe "parse_config/1" do
    test "nil and false disable stutter" do
      assert Stutter.parse_config(nil) == nil
      assert Stutter.parse_config(false) == nil
    end

    test "accepts the run/1 keyword-list shape (the documented + schema-validated form)" do
      config =
        Stutter.parse_config(
          probability: 1.0,
          max_repeats: 3,
          delay_ms: {10, 100},
          commands: [Cmd],
          comparison: :strict
        )

      assert %Config{
               probability: 1.0,
               max_repeats: 3,
               delay_ms: {10, 100},
               commands: [Cmd],
               comparison: :strict,
               enabled: true
             } = config
    end

    test "keyword list and equivalent map parse identically" do
      kw = [probability: 0.5, max_repeats: 2]
      assert Stutter.parse_config(kw) == Stutter.parse_config(Map.new(kw))
    end

    test "an empty keyword list uses defaults" do
      assert %Config{probability: 0.1, max_repeats: 2, commands: :all, enabled: true} =
               Stutter.parse_config([])
    end
  end
end
