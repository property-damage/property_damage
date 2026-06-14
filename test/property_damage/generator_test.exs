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

      for g <- generated do
        assert g.amount >= 100 and g.amount <= 200,
               "expected amount #{g.amount} to be between 100-200"
      end
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

  describe "generate_sequence/2 - linear sequences" do
    alias PropertyDamage.Test.FullModel
    alias PropertyDamage.Sequence

    test "generates linear sequence by default" do
      generator = Generator.generate_sequence(FullModel, max_commands: 10)

      sequences = Enum.take(generator, 5)

      for seq <- sequences do
        assert %Sequence{} = seq
        assert Sequence.linear?(seq)
        assert Sequence.command_count(seq) <= 10
      end
    end

    test "respects max_commands option" do
      generator = Generator.generate_sequence(FullModel, max_commands: 5)

      sequences = Enum.take(generator, 10)

      for seq <- sequences do
        assert Sequence.command_count(seq) <= 5
      end
    end

    test "generates valid command structs" do
      alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}

      generator = Generator.generate_sequence(FullModel, max_commands: 10)
      seq = Enum.take(generator, 1) |> hd()

      for cmd <- Sequence.to_list(seq) do
        assert cmd.__struct__ in [CreateItem, ViewItem, MinimalCommand]
      end
    end
  end

  describe "generate_sequence/2 - branching sequences" do
    alias PropertyDamage.Test.FullModel
    alias PropertyDamage.Sequence

    test "generates branching sequence with branching option" do
      generator =
        Generator.generate_sequence(FullModel,
          max_commands: 20,
          branching: [
            branch_probability: 1.0,
            max_branches: 2,
            max_branch_length: 3,
            min_prefix_length: 2
          ]
        )

      # Generate multiple sequences and check at least some are branching
      sequences = Enum.take(generator, 10)

      branching_count = Enum.count(sequences, &Sequence.branching?/1)
      # With branch_probability: 1.0, most should be branching
      assert branching_count > 0
    end

    test "branching sequence respects max_branches" do
      generator =
        Generator.generate_sequence(FullModel,
          max_commands: 30,
          branching: [
            branch_probability: 1.0,
            max_branches: 3,
            max_branch_length: 5,
            min_prefix_length: 2
          ]
        )

      sequences = Enum.take(generator, 10)

      for seq <- sequences do
        if Sequence.branching?(seq) do
          assert Sequence.branch_count(seq) <= 3
        end
      end
    end

    test "branching sequence respects max_branch_length" do
      generator =
        Generator.generate_sequence(FullModel,
          max_commands: 30,
          branching: [
            branch_probability: 1.0,
            max_branches: 2,
            max_branch_length: 4,
            min_prefix_length: 2
          ]
        )

      sequences = Enum.take(generator, 10)

      for seq <- sequences do
        if Sequence.branching?(seq) and not is_nil(seq.branches) do
          for branch <- seq.branches do
            assert length(branch) <= 4
          end
        end
      end
    end

    test "branching sequence has non-empty prefix" do
      generator =
        Generator.generate_sequence(FullModel,
          max_commands: 20,
          branching: [
            branch_probability: 1.0,
            max_branches: 2,
            max_branch_length: 3,
            min_prefix_length: 3
          ]
        )

      sequences = Enum.take(generator, 10)

      for seq <- sequences do
        if Sequence.branching?(seq) do
          # Branching sequences should have at least one command in prefix
          # (min_prefix_length is a soft constraint)
          assert seq.prefix != []
        end
      end
    end

    test "branching sequences contain valid commands" do
      alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}

      generator =
        Generator.generate_sequence(FullModel,
          max_commands: 20,
          branching: [branch_probability: 1.0, max_branches: 2]
        )

      sequences = Enum.take(generator, 5)

      for seq <- sequences do
        for cmd <- Sequence.to_list(seq) do
          assert cmd.__struct__ in [CreateItem, ViewItem, MinimalCommand]
        end
      end
    end
  end
end
