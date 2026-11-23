defmodule PropertyDamage.Next.Engine.StreamDataSource do
  @moduledoc """
  An engine that draws every generator through StreamData from a random
  source that records each range draw and fits it on replay.

  PD's descriptions are drawn this way too: `integer/1`, `member_of/1` and
  `boolean/0` are converted with `PropertyDamage.Next.Gen.to_stream_data/1`,
  so on this engine an integer or member field gives the same kind of entry
  as any other generator. Every draw is made at the size
  `PropertyDamage.Next.Steering.size/0`, as with PD's own engine.

  ## The source

  StreamData draws from a `:rand` state. This engine hands it a state of its
  own, seeded from `PropertyDamage.Next.Journal.key_seed/2`. A position in
  the source is `{split_path, counter}`: `counter` counts the draws and
  splits made on one state, and `split_path` lists, from the root, the
  counter of each split that led to that state. When StreamData splits the
  state, the child state starts at counter 0 under the split's position, and
  the parent moves on. When StreamData asks for an integer between two
  bounds, the source answers it and records `{value, lo, hi}` under the
  position.

  ## The entry

  The entry is `{:source, value, positions}`. `positions` lists each
  recorded position with its `{value, lo, hi}`, ordered so a position drawn
  inside a split comes before the positions its parent draws after the
  split. It holds integers and lists only, and no shrink-tree path.

  An integer field `integer(1..10)` that drew 7 records one position:
  `{:source, 7, [{{[0], 0}, {7, 1, 10}}]}`. A member field draws the index
  of its member, so `member_of([:a, :b, :c])` that drew `:c` records
  `{:source, :c, [{{[0], 0}, {2, 0, 2}}]}`. A nested value records one
  position per range draw it is made of, such as a list's length and each
  element's parts.

  ## Fitting

  On a key whose entry is a source entry, each position the draw visits
  again is answered from the entry. With the stored value, its stored upper
  bound and the bounds asked for now:

    * a value that sat on the stored upper bound, when the upper bound
      moved, takes the new upper bound;
    * otherwise a value outside the bounds is clamped to the nearer one;
    * otherwise the value is kept.

  A position the entry does not hold, such as an element of a list that
  grew, is drawn afresh from the source's generator, which is seeded from
  the key. A stored position the draw no longer visits is dropped from the
  new entry. A key with no entry, or with an entry of another kind, is
  drawn afresh. The same journal, key, generator and seed give the same
  value and entry in any VM.

  A member is fitted by its index, not by its identity: when the list is
  reordered, the member at the stored index is taken.

  ## Dependent generators

  A generator that a `from/2` function or a dependent assign returned is
  drawn the same way, so its value is fitted part by part when the value it
  depends on changes. This engine exports `fits_dependent?/1` answering
  `true`, so generation neither warns nor raises about such a site and
  keeps no site (see `PropertyDamage.Next.Engine`).

  ## The StreamData it needs

  The source works only with a StreamData whose `:rand` seams are open: one
  that lets a `:rand` state carrying `:split` split itself and hands a state
  carrying `:uniform_range` both bounds of every range draw. StreamData
  1.4.0 as released has neither seam. On it the source is asked only once,
  for the integer StreamData seeds its own state from, and the value is
  then drawn without the source, so nothing is recorded or fitted. The
  engine detects that the source was never split and raises
  `ArgumentError` saying so.
  """

  @behaviour PropertyDamage.Next.Engine

  alias PropertyDamage.Next.Engine.Dependent
  alias PropertyDamage.Next.{Gen, Journal, Steering}

  @tag :source

  @typedoc "Where the source drew: the split path from the root and the draw counter."
  @type position :: {[non_neg_integer()], non_neg_integer()}

  @typedoc "What the source recorded at a position: the value and the bounds asked for."
  @type drawn :: {integer(), integer(), integer()}

  @typedoc "An entry of this engine."
  @type entry :: {:source, term(), [{position(), drawn()}]}

  @doc "The tag of this engine's entries."
  @spec tag() :: :source
  def tag, do: @tag

  @doc "Answers `true`: this engine fits a dependent StreamData value."
  @spec fits_dependent?(term()) :: true
  def fits_dependent?(_generator), do: true

  @doc """
  The recorded positions of `entry`, each with the value and bounds drawn
  there, in draw order (see the module documentation).
  """
  @spec positions(entry()) :: [{position(), drawn()}]
  def positions({@tag, _value, positions}) when is_list(positions), do: positions

  @doc """
  `entry` with the value at `position` replaced by `value`, its recorded
  bounds kept. An entry that does not hold `position` is returned unchanged.
  """
  @spec put_position(entry(), position(), integer()) :: entry()
  def put_position({@tag, stored, positions}, position, value) when is_integer(value) do
    replaced =
      Enum.map(positions, fn
        {^position, {_old, lo, hi}} -> {position, {value, lo, hi}}
        other -> other
      end)

    {@tag, stored, replaced}
  end

  @impl true
  def draw(journal, key, %Dependent{generator: generator}, seed),
    do: draw(journal, key, generator, seed)

  def draw(%Journal{entries: entries}, key, generator, seed) do
    recorded =
      case Map.fetch(entries, key) do
        {:ok, {@tag, _value, positions}} when is_list(positions) -> Map.new(positions)
        _none_or_other -> %{}
      end

    {value, positions} =
      generator |> Gen.to_stream_data() |> run(recorded, Journal.key_seed(seed, key))

    {value, {@tag, value, positions}}
  end

  # Draws one value from `stream_data` through the source. What the source
  # records lives in the process dictionary under a fresh key for the length
  # of the draw: StreamData drops the states a split hands to child
  # generators, so the records cannot travel inside the state.
  defp run(stream_data, recorded, key_seed) do
    slot = {__MODULE__, make_ref()}
    Process.put(slot, %{split?: false, drawn: %{}})

    rng = :rand.seed_s(:exsss, {key_seed, 0, 0})

    options = [
      initial_seed: {handler(slot), {[], 0, recorded, rng}},
      initial_size: Steering.size(),
      max_runs: 1,
      max_shrinking_steps: 0
    ]

    try do
      {:error, %{original_failure: value}} =
        StreamData.check_all(stream_data, options, &{:error, &1})

      %{split?: split?, drawn: drawn} = Process.get(slot)
      unless split?, do: closed_seams!()
      {value, in_draw_order(drawn)}
    after
      Process.delete(slot)
    end
  end

  # The `:rand` algorithm map of the source. StreamData calls `:split` and
  # `:uniform_range` when its seams are open; `:uniform_n` serves the other
  # integer draws `:rand.uniform_s/2` makes. A source never needs `next` or
  # `uniform`.
  defp handler(slot) do
    %{
      type: __MODULE__,
      bits: 58,
      weak_low_bits: 0,
      next: fn _state -> closed_seams!() end,
      uniform: fn _state -> closed_seams!() end,
      uniform_n: fn count, {handler, {path, n, recorded, rng}} ->
        {value, rng} = :rand.uniform_s(count, rng)
        {value, {handler, {path, n + 1, recorded, rng}}}
      end,
      split: fn {handler, {path, n, recorded, rng}} ->
        Process.put(slot, %{Process.get(slot) | split?: true})
        {int, rng} = :rand.uniform_s(1_000_000_000, rng)
        child = {handler, {[n | path], 0, recorded, :rand.seed_s(:exsss, {int, 0, 0})}}
        {child, {handler, {path, n + 1, recorded, rng}}}
      end,
      uniform_range: fn lo, hi, {handler, {path, n, recorded, rng}} ->
        position = {Enum.reverse(path), n}

        {value, rng} =
          case Map.fetch(recorded, position) do
            {:ok, {stored, _stored_lo, stored_hi}} -> {fit(stored, stored_hi, lo, hi), rng}
            :error -> fresh(lo, hi, rng)
          end

        record(slot, position, {value, lo, hi})
        {value, {handler, {path, n + 1, recorded, rng}}}
      end
    }
  end

  defp fresh(lo, hi, rng) do
    {value, rng} = :rand.uniform_s(hi - lo + 1, rng)
    {value - 1 + lo, rng}
  end

  # A value on the stored upper bound follows that bound when it moves;
  # otherwise the value is clamped into the bounds, or kept.
  defp fit(stored, stored_hi, lo, hi) do
    cond do
      stored == stored_hi and hi != stored_hi -> hi
      stored < lo -> lo
      stored > hi -> hi
      true -> stored
    end
  end

  defp record(slot, position, drawn) do
    state = Process.get(slot)
    Process.put(slot, %{state | drawn: Map.put(state.drawn, position, drawn)})
  end

  # A position's draw order is its split path followed by its counter,
  # compared as a list: a draw inside a split sorts before the parent's
  # later draws, since a counter is used by one draw or one split only.
  defp in_draw_order(drawn), do: Enum.sort_by(drawn, fn {{path, n}, _drawn} -> path ++ [n] end)

  defp closed_seams! do
    raise ArgumentError,
          "#{inspect(__MODULE__)} needs a StreamData whose :rand seams are open: a :rand " <>
            "state carrying :split must split itself, and one carrying :uniform_range must " <>
            "receive both bounds of every range draw. The StreamData loaded here has neither " <>
            "seam (StreamData 1.4.0 as released lacks them), so the source cannot record " <>
            "or fit any draw."
  end
end
