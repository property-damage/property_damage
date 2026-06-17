defmodule PropertyDamage.StutterTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Stutter
  alias PropertyDamage.Stutter.Config

  defmodule Cmd do
    defstruct []
  end

  describe "should_stutter?/2" do
    test "returns false when the config is disabled" do
      config = %Config{
        probability: 1.0,
        max_repeats: 2,
        delay_ms: {0, 0},
        commands: :all,
        comparison: :strict,
        enabled: false
      }

      refute Stutter.should_stutter?(%Cmd{}, config)
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

      assert Stutter.should_stutter?(%Cmd{}, config)
    end
  end

  describe "retry_delay_ms/1" do
    test "returns a delay within the configured range" do
      config = %Config{delay_ms: {10, 20}}
      delay = Stutter.retry_delay_ms(config)
      assert delay >= 10 and delay <= 20
    end

    test "does not raise on an inverted {max < min} delay tuple" do
      config = %Config{delay_ms: {100, 0}}
      delay = Stutter.retry_delay_ms(config)
      assert delay >= 0 and delay <= 100
    end
  end
end
