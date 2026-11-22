defmodule PropertyDamage.Next.GenTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next.Gen
  alias PropertyDamage.Next.Test.Terms

  # StreamData's public functions that do not build a generator, so PD's
  # generator module has no reason to mirror them. Each entry says why.
  @not_generators %{
    {:check_all, 3} => "runs a property over a generator and returns its result",
    {:__call__, 3} => "internal entry point StreamData uses to run a generator (@doc false)",
    {:__reduce__, 3} => "internal helper behind StreamData's Enumerable implementation",
    {:__struct__, 0} => "the struct definition, not a function users call",
    {:__struct__, 1} => "the struct definition, not a function users call"
  }

  # The three names PD answers with a description instead of a delegated
  # generator.
  @descriptions [integer: 1, member_of: 1, boolean: 0]

  defp stream_data_generators do
    StreamData.__info__(:functions) |> Enum.reject(&Map.has_key?(@not_generators, &1))
  end

  defp values(generator, count \\ 60),
    do: generator |> Gen.to_stream_data() |> Enum.take(count)

  describe "the export list" do
    test "exports every StreamData generator function under the same name and arity" do
      exported = MapSet.new(Gen.__info__(:functions))

      missing = Enum.reject(stream_data_generators(), &MapSet.member?(exported, &1))

      assert missing == [],
             "PropertyDamage.Next.Gen lacks these StreamData generators: #{inspect(missing)}"
    end

    test "every name on the exclusion list is still a public StreamData function" do
      stream_data = StreamData.__info__(:functions)

      stale = Enum.reject(Map.keys(@not_generators), &(&1 in stream_data))

      assert stale == [], "excluded names StreamData no longer exports: #{inspect(stale)}"
    end
  end

  describe "descriptions" do
    test "integer/1 describes an integer draw over the range" do
      assert Gen.integer(1..5) == %Gen{kind: :integer, domain: 1..5}
    end

    test "member_of/1 describes a member draw over the list" do
      assert Gen.member_of([:a, :b]) == %Gen{kind: :member, domain: [:a, :b]}
    end

    test "boolean/0 describes a member draw over false and true" do
      assert Gen.boolean() == %Gen{kind: :member, domain: [false, true]}
    end

    test "integer/1 keeps StreamData's own refusal of an argument that is not a range" do
      assert %{__exception__: true} = Terms.raised(fn -> Gen.integer(:not_a_range) end)
    end

    test "a description converts to a StreamData generator that draws inside its domain" do
      assert %StreamData{} = Gen.to_stream_data(Gen.integer(1..5))
      assert Enum.all?(values(Gen.integer(3..5)), &(&1 in 3..5))
      assert Enum.all?(values(Gen.member_of([:a, :b])), &(&1 in [:a, :b]))
      assert Enum.all?(values(Gen.boolean()), &is_boolean/1)
    end

    test "to_stream_data/1 returns a StreamData generator unchanged and unwraps a delegated one" do
      generator = StreamData.integer(1..3)

      assert Gen.to_stream_data(generator) == generator
      assert %Gen{kind: :delegated, domain: %StreamData{} = inner} = Gen.constant(:x)
      assert Gen.to_stream_data(Gen.constant(:x)) == inner
    end
  end

  describe "delegated generators" do
    # One call per StreamData generator name that PD delegates.
    defp sample_calls do
      [
        {:atom, [:alphanumeric]},
        {:binary, []},
        {:binary, [[length: 2]]},
        {:bind, [StreamData.constant(1), fn x -> StreamData.constant(x) end]},
        {:bind_filter, [StreamData.constant(1), fn x -> {:cont, StreamData.constant(x)} end]},
        {:bind_filter, [StreamData.constant(1), fn x -> {:cont, StreamData.constant(x)} end, 5]},
        {:bitstring, []},
        {:bitstring, [[length: 3]]},
        {:byte, []},
        {:chardata, []},
        {:codepoint, []},
        {:codepoint, [:ascii]},
        {:constant, [1]},
        {:date, []},
        {:date, [[]]},
        {:filter, [StreamData.integer(1..9), &(&1 > 0)]},
        {:filter, [StreamData.integer(1..9), &(&1 > 0), 5]},
        {:fixed_list, [[StreamData.constant(1)]]},
        {:fixed_map, [%{a: StreamData.constant(1)}]},
        {:float, []},
        {:float, [[min: 0.0]]},
        {:frequency, [[{1, StreamData.constant(1)}]]},
        {:integer, []},
        {:iodata, []},
        {:iolist, []},
        {:keyword_of, [StreamData.constant(1)]},
        {:list_of, [StreamData.constant(1)]},
        {:list_of, [StreamData.constant(1), [length: 2]]},
        {:map, [StreamData.constant(1), &(&1 + 1)]},
        {:map_of, [StreamData.constant(:k), StreamData.constant(1)]},
        {:map_of, [StreamData.integer(1..99), StreamData.constant(1), [max_length: 2]]},
        {:mapset_of, [StreamData.integer(1..99)]},
        {:mapset_of, [StreamData.integer(1..99), [max_length: 2]]},
        {:maybe_improper_list_of, [StreamData.constant(1), StreamData.constant(2)]},
        {:non_negative_integer, []},
        {:nonempty, [StreamData.list_of(StreamData.constant(1))]},
        {:nonempty_improper_list_of, [StreamData.constant(1), StreamData.constant(2)]},
        {:nullable, [StreamData.constant(1)]},
        {:nullable, [StreamData.constant(1), [ratio: 0.5]]},
        {:one_of, [[StreamData.constant(1)]]},
        {:optional_map, [%{a: StreamData.constant(1)}]},
        {:optional_map, [%{a: StreamData.constant(1)}, [:a]]},
        {:positive_integer, []},
        {:repeatedly, [fn -> 1 end]},
        {:resize, [StreamData.constant(1), 3]},
        {:scale, [StreamData.constant(1), &(&1 * 2)]},
        {:seeded, [StreamData.constant(1), 42]},
        {:shuffle, [[1, 2, 3]]},
        {:sized, [fn _size -> StreamData.constant(1) end]},
        {:string, [:ascii]},
        {:string, [:ascii, [max_length: 3]]},
        {:term, []},
        {:tree, [StreamData.constant(1), &StreamData.list_of/1]},
        {:tuple, [{StreamData.constant(1)}]},
        {:uniq_list_of, [StreamData.integer(1..99)]},
        {:uniq_list_of, [StreamData.integer(1..99), [max_length: 2]]},
        {:unshrinkable, [StreamData.constant(1)]}
      ]
    end

    test "the sample calls cover every delegated name and arity" do
      sampled = MapSet.new(sample_calls(), fn {name, args} -> {name, length(args)} end)
      delegated = stream_data_generators() -- @descriptions

      assert Enum.reject(delegated, &MapSet.member?(sampled, &1)) == []
    end

    test "every name except the three descriptions returns a tagged StreamData generator" do
      for {name, args} <- sample_calls() do
        assert %Gen{kind: :delegated, domain: %StreamData{}} = apply(Gen, name, args),
               "#{name}/#{length(args)} did not return a delegated generator"
      end
    end

    test "a delegated generator draws what StreamData's generator draws" do
      assert values(Gen.constant(:same)) |> Enum.uniq() == [:same]
      assert Enum.all?(values(Gen.list_of(StreamData.integer(1..2))), &is_list/1)
    end
  end

  describe "a description passed to a delegated combinator" do
    test "list_of/1 converts it and draws lists of values in its domain" do
      lists = values(Gen.list_of(Gen.integer(1..5)))

      assert Enum.all?(lists, &is_list/1)
      assert lists |> List.flatten() |> Enum.all?(&(&1 in 1..5))
      assert lists |> List.flatten() |> Enum.uniq() |> length() > 1
    end

    test "tuple/1 converts the descriptions inside the tuple" do
      for {flag, letter} <- values(Gen.tuple({Gen.boolean(), Gen.member_of([:a, :b])})) do
        assert is_boolean(flag)
        assert letter in [:a, :b]
      end
    end

    test "bind/2 converts its source and a description its function returns" do
      drawn = values(Gen.bind(Gen.integer(1..3), fn n -> Gen.integer((n * 10)..(n * 10 + 1)) end))

      assert Enum.all?(drawn, &(&1 in [10, 11, 20, 21, 30, 31]))
    end

    test "a description nested in lists, maps and keyword arguments is converted" do
      assert Enum.all?(values(Gen.list_of(Gen.list_of(Gen.boolean()))), fn outer ->
               Enum.all?(outer, fn inner -> Enum.all?(inner, &is_boolean/1) end)
             end)

      for map <- values(Gen.fixed_map(%{a: Gen.integer(1..3), b: Gen.constant(:x)})) do
        assert map.a in 1..3
        assert map.b == :x
      end

      assert Enum.all?(
               values(Gen.one_of([Gen.integer(1..2), Gen.member_of([:z])])),
               &(&1 in [1, 2, :z])
             )

      assert Enum.all?(
               values(Gen.frequency([{1, Gen.boolean()}, {2, Gen.integer(7..7)}])),
               &(&1 in [false, true, 7])
             )

      assert Enum.all?(values(Gen.list_of(Gen.integer(4..4), length: 3)), &(&1 == [4, 4, 4]))
    end

    test "the result of a delegated combinator is a delegated generator, not a description" do
      assert %Gen{kind: :delegated} = Gen.list_of(Gen.integer(1..5))
      assert %Gen{kind: :delegated} = Gen.tuple({Gen.boolean()})
      assert %Gen{kind: :delegated} = Gen.bind(Gen.integer(1..2), &Gen.integer(&1..&1))
    end
  end
end
