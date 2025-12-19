defmodule PropertyDamage.GeneratorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Generator

  describe "merge_overrides/2" do
    test "wraps raw values as StreamData.constant" do
      base = %{
        amount: StreamData.positive_integer(),
        currency: StreamData.member_of(["USD", "EUR"])
      }

      result = Generator.merge_overrides(base, %{currency: "GBP"})

      # Generate a value to verify the override works
      generated =
        result
        |> StreamData.fixed_map()
        |> Enum.take(1)
        |> hd()

      assert generated.currency == "GBP"
      assert is_integer(generated.amount)
      assert generated.amount > 0
    end

    test "passes through StreamData generators unchanged" do
      base = %{
        amount: StreamData.positive_integer(),
        currency: StreamData.constant("USD")
      }

      override_gen = StreamData.integer(100..200)
      result = Generator.merge_overrides(base, %{amount: override_gen})

      # Generate values to verify the override generator works
      generated =
        result
        |> StreamData.fixed_map()
        |> Enum.take(10)

      assert Enum.all?(generated, fn g -> g.amount >= 100 and g.amount <= 200 end)
    end

    test "preserves base generators when no override provided" do
      base = %{
        name: StreamData.string(:alphanumeric, min_length: 1),
        age: StreamData.positive_integer()
      }

      result = Generator.merge_overrides(base, %{name: "Alice"})

      generated =
        result
        |> StreamData.fixed_map()
        |> Enum.take(1)
        |> hd()

      assert generated.name == "Alice"
      assert is_integer(generated.age)
    end

    test "handles empty overrides" do
      base = %{
        x: StreamData.integer(),
        y: StreamData.integer()
      }

      result = Generator.merge_overrides(base, %{})

      # Should return equivalent to base
      generated =
        result
        |> StreamData.fixed_map()
        |> Enum.take(1)
        |> hd()

      assert is_integer(generated.x)
      assert is_integer(generated.y)
    end

    test "handles nil values correctly" do
      base = %{
        ref: StreamData.constant(:placeholder),
        name: StreamData.string(:alphanumeric)
      }

      result = Generator.merge_overrides(base, %{ref: nil})

      generated =
        result
        |> StreamData.fixed_map()
        |> Enum.take(1)
        |> hd()

      assert generated.ref == nil
    end

    test "can add new keys not in base" do
      base = %{
        name: StreamData.constant("test")
      }

      result = Generator.merge_overrides(base, %{extra: "value"})

      generated =
        result
        |> StreamData.fixed_map()
        |> Enum.take(1)
        |> hd()

      assert generated.name == "test"
      assert generated.extra == "value"
    end
  end

  describe "stream_data?/1" do
    test "returns true for StreamData generators" do
      assert Generator.stream_data?(StreamData.integer())
      assert Generator.stream_data?(StreamData.string(:alphanumeric))
      assert Generator.stream_data?(StreamData.constant(42))
      assert Generator.stream_data?(StreamData.member_of([1, 2, 3]))
    end

    test "returns false for raw values" do
      refute Generator.stream_data?(42)
      refute Generator.stream_data?("hello")
      refute Generator.stream_data?(:atom)
      refute Generator.stream_data?([1, 2, 3])
      refute Generator.stream_data?(%{a: 1})
      refute Generator.stream_data?(nil)
    end
  end

  describe "integration with command pattern" do
    test "works with typical command generator pattern" do
      # Simulate a command's generator/1 function
      generator = fn overrides ->
        %{
          amount: StreamData.positive_integer(),
          currency: StreamData.member_of(["USD", "EUR", "GBP"])
        }
        |> Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end

      # Test with no overrides
      check all(command <- generator.(%{})) do
        assert is_integer(command.amount)
        assert command.amount > 0
        assert command.currency in ["USD", "EUR", "GBP"]
      end

      # Test with static override
      check all(command <- generator.(%{currency: "USD"})) do
        assert command.currency == "USD"
      end

      # Test with generator override
      check all(command <- generator.(%{amount: StreamData.integer(1..5)})) do
        assert command.amount >= 1 and command.amount <= 5
      end
    end
  end
end
