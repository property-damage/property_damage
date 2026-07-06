defmodule PropertyDamage.RunComparison.Align do
  @moduledoc false
  # Alignment primitives for RunComparison (DR-035).
  #
  # Command alignment is trivial: same-plan traces share branch-aware
  # %Sequence.Position{} keys (DR-036), so commands align by position, total and
  # order-free. Events *within* a command align by longest-common-subsequence
  # keyed on the event struct module (or a model-supplied identity override), so
  # a single inserted event yields one gap rather than cascading every later row
  # into "different".

  @doc """
  Align N event lists to the reference (index 0) via LCS on `identity`.

  Returns a list of rows in reference order followed by any unmatched
  (inserted) events from the other traces. Each row is:

      %{key: term, events: %{trace_index => event | :absent}}

  `identity` maps an event to its alignment key (default: its struct module).
  """
  @spec align_events([[struct()]], (struct() -> term())) :: [
          %{key: term(), events: %{non_neg_integer() => struct() | :absent}}
        ]
  def align_events(event_lists, identity \\ &default_identity/1)

  def align_events([], _identity), do: []

  def align_events([reference | others], identity) do
    trace_count = length(others) + 1

    # One row per reference event, carrying the reference's event in column 0.
    base_rows =
      reference
      |> Enum.map(fn ev -> %{key: identity.(ev), events: %{0 => ev}} end)

    ref_keys = Enum.map(reference, identity)

    {rows, extra_rows} =
      others
      |> Enum.with_index(1)
      |> Enum.reduce({base_rows, []}, fn {events, col}, {rows, extras} ->
        keys = Enum.map(events, identity)
        matched = lcs_pairs(ref_keys, keys)
        matched_map = Map.new(matched)

        # Fill matched reference rows with this column's event.
        rows =
          rows
          |> Enum.with_index()
          |> Enum.map(fn {row, ref_idx} ->
            case Map.get(matched_map, ref_idx) do
              nil -> row
              col_idx -> put_in(row.events[col], Enum.at(events, col_idx))
            end
          end)

        # Events in this column not matched to any reference event are insertions.
        matched_cols = MapSet.new(matched, fn {_ref, col_idx} -> col_idx end)

        new_extras =
          events
          |> Enum.with_index()
          |> Enum.reject(fn {_ev, i} -> MapSet.member?(matched_cols, i) end)
          |> Enum.map(fn {ev, _i} -> %{key: identity.(ev), events: %{col => ev}} end)

        {rows, extras ++ new_extras}
      end)

    # Fill absent columns explicitly so every row spans all traces.
    (rows ++ extra_rows)
    |> Enum.map(fn row ->
      events =
        Enum.reduce(0..(trace_count - 1)//1, row.events, fn i, acc ->
          Map.put_new(acc, i, :absent)
        end)

      %{row | events: events}
    end)
  end

  defp default_identity(%{__struct__: mod}), do: mod
  defp default_identity(other), do: other

  # Longest common subsequence of two key lists; returns matched index pairs
  # {i, j} (i into a, j into b), strictly increasing in both. Standard DP where
  # table[{i, j}] is the LCS length of a[i..] and b[j..], built bottom-up so
  # every cell a cell depends on ({i+1,j+1}, {i+1,j}, {i,j+1}) is already set.
  @spec lcs_pairs([term()], [term()]) :: [{non_neg_integer(), non_neg_integer()}]
  def lcs_pairs(a, b) do
    av = List.to_tuple(a)
    bv = List.to_tuple(b)
    n = tuple_size(av)
    m = tuple_size(bv)

    table =
      Enum.reduce(n..0//-1, %{}, fn i, table ->
        Enum.reduce(m..0//-1, table, fn j, table ->
          value =
            cond do
              i == n or j == m -> 0
              elem(av, i) == elem(bv, j) -> 1 + table[{i + 1, j + 1}]
              true -> max(table[{i + 1, j}], table[{i, j + 1}])
            end

          Map.put(table, {i, j}, value)
        end)
      end)

    backtrack(av, bv, table, 0, 0, n, m, [])
  end

  defp backtrack(_av, _bv, _table, i, j, n, m, acc) when i == n or j == m do
    Enum.reverse(acc)
  end

  defp backtrack(av, bv, table, i, j, n, m, acc) do
    cond do
      elem(av, i) == elem(bv, j) ->
        backtrack(av, bv, table, i + 1, j + 1, n, m, [{i, j} | acc])

      Map.fetch!(table, {i + 1, j}) >= Map.fetch!(table, {i, j + 1}) ->
        backtrack(av, bv, table, i + 1, j, n, m, acc)

      true ->
        backtrack(av, bv, table, i, j + 1, n, m, acc)
    end
  end
end
