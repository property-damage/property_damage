defmodule PropertyDamage.Next.StreamDataSourceTest do
  # The engine that draws every generator through StreamData from a random
  # source that records each range draw under its position and fits the
  # stored value when the bounds asked for there change.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data

  alias PropertyDamage.Next.Engine.{Dependent, StreamDataSource}
  alias PropertyDamage.Next.{Gen, Journal}

  @key {{0, 3}, :command, :refund}
  @seed 41

  defp draw(generator, entries \\ %{}),
    do: StreamDataSource.draw(%Journal{seed: @seed, entries: entries}, @key, generator, @seed)

  defp redraw(entry, generator), do: draw(generator, %{@key => entry})

  defp refund(left, currencies),
    do: Gen.fixed_map(amount: Gen.integer(1..left), currency: Gen.member_of(currencies))

  # The single position whose recorded bounds are `lo..hi`.
  defp position(entry, lo, hi) do
    [position] =
      for {position, {_value, ^lo, ^hi}} <- StreamDataSource.positions(entry), do: position

    position
  end

  defp set(entry, position, value), do: StreamDataSource.put_position(entry, position, value)

  describe "a fresh draw" do
    test "records the value and each position with its value and bounds, and no path" do
      assert {value, {:source, value, [{position, {value, 1, 10}}]} = entry} =
               draw(Gen.integer(1..10))

      assert {[_ | _], 0} = position
      assert value in 1..10
      assert StreamDataSource.tag() == :source
      assert :erlang.binary_to_term(:erlang.term_to_binary(entry)) == entry

      {_value, {:source, _currency, positions}} = draw(refund(500, [:eur, :usd]))

      assert positions |> Enum.map(&elem(&1, 1)) |> Enum.map(&Tuple.delete_at(&1, 0)) == [
               {1, 500},
               {0, 1}
             ]
    end

    test "gives the same value and entry for the same journal, key, generator and seed" do
      generator = Gen.list_of(refund(500, [:eur, :usd, :chf]), max_length: 4)
      assert draw(generator) == draw(generator)

      {_value, entry} = draw(generator)
      assert redraw(entry, generator) == redraw(entry, generator)
      assert redraw(entry, generator) == draw(generator)
    end

    test "draws a dependent generator as the bare generator, and fits such a value" do
      generator = StreamData.integer(1..9)
      dependent = %Dependent{generator: generator, site: %{site: :field}}

      assert draw(dependent) == draw(generator)
      assert StreamDataSource.fits_dependent?(generator) == true
    end
  end

  describe "a number fits position by position" do
    setup do
      {_value, entry} = draw(refund(500, [:eur, :usd, :chf]))
      %{entry: entry, amount: position(entry, 1, 500)}
    end

    # {stored amount, new upper bound, amount drawn}
    @rows [
      # Inside the new bounds: kept.
      {300, 400, 300},
      # Inside the old bounds, over the new upper bound: clamped.
      {300, 200, 200},
      # On the old upper bound, which moved down: the new upper bound.
      {500, 200, 200},
      # On the old upper bound, which moved up: the new upper bound.
      {500, 800, 800}
    ]

    for {stored, left, drawn} <- @rows do
      test "an amount of #{stored} drawn from 1..500, redrawn from 1..#{left}, gives #{drawn}",
           %{entry: entry, amount: amount} do
        stored_entry = set(entry, amount, unquote(stored))

        assert {%{amount: unquote(stored)}, _entry} =
                 redraw(stored_entry, refund(500, [:eur, :usd, :chf]))

        assert {%{amount: unquote(drawn)}, new_entry} =
                 redraw(stored_entry, refund(unquote(left), [:eur, :usd, :chf]))

        assert {^amount, {unquote(drawn), 1, unquote(left)}} =
                 List.keyfind(StreamDataSource.positions(new_entry), amount, 0)
      end
    end
  end

  describe "a member fits by its index" do
    setup do
      {_value, entry} = draw(refund(500, [:eur, :usd, :chf]))
      %{entry: entry, currency: position(entry, 0, 2)}
    end

    test "a stored index past the end of a shorter list gives the last member",
         %{entry: entry, currency: currency} do
      stored = set(entry, currency, 2)

      assert {%{currency: :chf}, _entry} = redraw(stored, refund(500, [:eur, :usd, :chf]))
      assert {%{currency: :usd}, _entry} = redraw(stored, refund(500, [:eur, :usd]))
    end

    test "a reordered list gives the member now at the stored index, not the stored member",
         %{entry: entry, currency: currency} do
      stored = set(entry, currency, 1)

      assert {%{currency: :usd}, _entry} = redraw(stored, refund(500, [:eur, :usd, :chf]))
      assert {%{currency: :eur}, _entry} = redraw(stored, refund(500, [:usd, :eur, :chf]))
    end
  end

  describe "a nested value" do
    # A list of refunds whose amounts and currencies depend on what is left.
    defp refunds(left, currencies),
      do: Gen.list_of(refund(left, currencies), min_length: 2, max_length: 4)

    test "a changed generator fits each part of each element on its own" do
      {before, entry} = draw(refunds(500, [:eur, :usd, :chf]))
      positions = StreamDataSource.positions(entry)

      amounts = for {position, {_value, 1, 500}} <- positions, do: position
      currencies = for {position, {_value, 0, 2}} <- positions, do: position
      assert length(amounts) == length(before) and length(currencies) == length(before)

      # Give the elements amounts inside, over and on the old upper bound,
      # and currencies at the last index and inside.
      stored =
        amounts
        |> Enum.zip(Stream.cycle([150, 300, 500]))
        |> Enum.reduce(entry, fn {position, value}, acc -> set(acc, position, value) end)

      stored =
        currencies
        |> Enum.zip(Stream.cycle([2, 0]))
        |> Enum.reduce(stored, fn {position, value}, acc -> set(acc, position, value) end)

      {after_change, _entry} = redraw(stored, refunds(200, [:eur, :usd]))

      # Positions are in draw order, and list_of/2 puts the element drawn
      # last first.
      in_draw_order =
        for index <- 0..(length(before) - 1) do
          %{
            amount: Enum.at([150, 200, 200], rem(index, 3)),
            currency: Enum.at([:usd, :eur], rem(index, 2))
          }
        end

      assert Enum.reverse(after_change) == in_draw_order
    end

    test "a list that grows draws its new positions afresh; one that shrinks drops the positions it no longer visits" do
      # list_of/2 puts the element drawn last first, so the elements a
      # length change keeps are at the end of the list.
      generator = refunds(500, [:eur, :usd, :chf])
      {before, entry} = draw(generator)
      [{length_position, {count, 2, 4}} | _rest] = StreamDataSource.positions(entry)
      assert count == length(before)

      {longer, longer_entry} = redraw(set(entry, length_position, 4), generator)
      assert length(longer) == 4
      assert Enum.take(longer, -count) == before
      assert length(StreamDataSource.positions(longer_entry)) == 1 + 4 * 2

      {shorter, shorter_entry} = redraw(set(longer_entry, length_position, 2), generator)
      assert shorter == Enum.take(longer, -2)
      assert length(StreamDataSource.positions(shorter_entry)) == 1 + 2 * 2

      for {position, _drawn} = recorded <- StreamDataSource.positions(shorter_entry),
          position != length_position,
          do: assert(recorded in StreamDataSource.positions(longer_entry))
    end
  end
end
