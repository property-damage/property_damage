defmodule PropertyDamage.Next.Shrinker do
  @moduledoc false
  # Shrinks a failing plan by editing its journal. Each candidate is an
  # edited journal; generation rebuilds its plan, fitting every stored value
  # to the domain it has now, and the plan is executed. A candidate is
  # adopted when it fails the same way as the plan it shrinks: the same
  # kind of reason (see `class/1`) at the same step or an earlier one. A
  # candidate whose rebuilt plan has the steps and the schedule of the plan
  # it shrinks is that same test case, and it is not executed.
  #
  # The passes, repeated until a round adopts nothing or the run budget is
  # spent:
  #
  #   1. once, first: empty every slot that runs after the failing step:
  #      later slots of its lane, and every lane slot after a prefix step;
  #   2. remove steps in blocks, halving the block size down to one step,
  #      by writing the empty pick `{:empty}` at each slot of the block;
  #   3. lower the drawn values, in three phases:
  #      a. find the values that must keep their stored value. A value is an
  #         integer entry above its range's first value, a member above
  #         index 0, or one recorded position of a source entry above its
  #         lower bound, in draw order; its minimum is that first value,
  #         index 0 or that lower bound. The first candidate puts every
  #         value at its minimum. If it does not fail the same way, a
  #         bisection over the set of values (QuickXplain) finds a set to
  #         keep such that the candidate with every other value at its
  #         minimum fails the same way, and that candidate is adopted.
  #         Every candidate of this phase is built from the journal held
  #         when the phase starts. One that rebuilds the plan held fails
  #         the same way and costs no run;
  #      b. bisect each kept value between its minimum and its stored
  #         value, later slots first and, within a slot, in the reverse of
  #         the draw order, so a value drawn from another field is lowered
  #         before the field it depends on;
  #      c. extend the path of each StreamData value in its shrink tree,
  #         later slots first, trying the node's children in order and
  #         descending into the first that fails;
  #   4. only after a round in which passes 2 and 3 adopted nothing: remove
  #      each step together with the later steps whose command holds a
  #      placeholder of it, a removal no single block can make when the
  #      later steps would otherwise pick another step's value; the first
  #      removal adopted starts the rounds again from pass 2;
  #   5. only after a round in which passes 2 to 4 adopted nothing: lower
  #      pairs of values by the same amount, for a failure that needs two
  #      values to fall together, which no single edit can keep. A value is
  #      an integer entry or one recorded position of a source entry, above
  #      its lower bound; two positions of one source entry also form a
  #      pair. A value whose bisection in pass 3b of the round just ended
  #      rebuilt only the plan already held is left out, such as a position of a
  #      string's character that does not reach the string: a pair with it
  #      would in effect lower the other value alone. A pair tries
  #      the largest amount both can fall first, then bisects for the
  #      largest amount that still fails the same way. The first pair
  #      adopted starts the rounds again from pass 2.
  #
  # Slots are withdrawn by generation, not by the shrinker: an edit that
  # leaves a stored pick no longer offered withdraws that slot, which keeps
  # its entries in the rebuilt journal so a later edit can bring it back.
  #
  # A stored integer that sat on a bound of its stored range and was kept
  # although that bound moved is tried at the new bound once, right after
  # the candidate that kept it was not adopted. In pass 3a the retried plan
  # answers for the set of kept values that made the first.
  #
  # Within one round a plan is executed at most once: a candidate whose
  # rebuilt plan the round already executed takes that execution's answer.
  #
  # The final journal drops what the search kept: each withdrawn slot's
  # pick becomes `{:empty}` and its other entries go, so the journal holds
  # exactly its plan's draws. The plan it rebuilds is executed once more,
  # and that execution is the failure returned.
  #
  # Every execution after the plan that first failed counts as a shrink
  # run, the last one included, and there are at most `max_runs` of them.
  # When the budget ends inside pass 3a, the failing candidate of the phase
  # with the fewest kept values is adopted before the last execution.

  alias PropertyDamage.Next.Engine.StreamDataSource
  alias PropertyDamage.Next.{Journal, Placeholder, Plan}

  # The tag of an entry that records positions of a random source; its
  # positions are read and written only through the engine that writes it.
  @source StreamDataSource.tag()

  # A value written at a member's key to ask for the member at an index: it
  # is in no list, so the engine takes the member at the stored index.
  @no_member {__MODULE__, :member_at_index}

  @typedoc """
  The current best failure: its plan, the keys drawn in order, and the
  step and reason of its execution.
  """
  @type best :: %{plan: Plan.t(), drawn: [term()], step: term(), reason: term()}

  @doc """
  Shrinks `best`. `build` rebuilds a plan from a journal and lists its draw
  keys in order; `execute` runs a plan and answers `:ok` or
  `{:error, step, reason}`. Returns `{best, runs}`; `search/4` also says
  what ended the search.
  """
  @spec shrink(best(), (Journal.t() -> {Plan.t(), [term()]}), (Plan.t() -> term()), pos_integer()) ::
          {best(), non_neg_integer()}
  def shrink(best, build, execute, max_runs) do
    {final, runs, _ended} = search(best, build, execute, max_runs)
    {final, runs}
  end

  @doc """
  As `shrink/4`, but returns `{best, runs, ended}`, where `ended` is `:cap`
  when the run budget ended the search and `:done` when the passes ran out
  of candidates to adopt.
  """
  @spec search(best(), (Journal.t() -> {Plan.t(), [term()]}), (Plan.t() -> term()), pos_integer()) ::
          {best(), non_neg_integer(), :cap | :done}
  def search(best, build, execute, max_runs) do
    state = %{
      best: best,
      build: build,
      execute: execute,
      runs: 0,
      limit: max_runs - 1,
      lowering: nil,
      alone: %{},
      ran: %{},
      kept_search: nil
    }

    {searched, ended} =
      try do
        {state |> cut_after_failure() |> elem(1) |> rounds(), :done}
      catch
        {__MODULE__, :spent, spent} -> {adopt_fewest_kept(spent), :cap}
      end

    {final, runs} = finish(searched)
    {final, runs, ended}
  end

  # --- Passes

  defp rounds(state) do
    {removed?, state} = remove_blocks(%{state | ran: %{}})
    {fixed?, kept, state} = find_kept(%{state | alone: %{}})
    {narrowed?, state} = narrow(state, kept)
    {walked?, state} = walk_trees(state)

    if removed? or fixed? or narrowed? or walked?,
      do: rounds(state),
      else: after_stable_round(state)
  end

  # A round of single edits kept nothing: try removing steps with their
  # dependents, then pairs, and start the rounds again if one is kept.
  defp after_stable_round(state) do
    with {false, state} <- remove_dependents(state),
         {false, state} <- lower_pairs(state) do
      state
    else
      {true, state} -> rounds(state)
    end
  end

  # Removes a step together with every later step whose command holds a
  # placeholder of it. Block removal cannot make this edit when the steps
  # lie apart: removing the step alone leaves its dependents to pick
  # another step's value, and removing a dependent alone leaves the step.
  defp remove_dependents(state) do
    steps = state.best.plan.steps

    candidates =
      for {step, index} <- Enum.with_index(steps),
          dependents =
            for(
              later <- Enum.drop(steps, index + 1),
              holds?(later.command, step.key),
              do: later.key
            ),
          dependents != [],
          do: [step.key | dependents]

    first_adopted(state, candidates, &emptied/2)
  end

  # Whether `term` holds a placeholder minted by the step at `key`.
  defp holds?(%Placeholder{step: step}, key), do: step == key
  defp holds?(%_{} = struct, key), do: struct |> Map.from_struct() |> holds?(key)
  defp holds?(map, key) when is_map(map), do: Enum.any?(map, fn {_k, v} -> holds?(v, key) end)
  defp holds?(list, key) when is_list(list), do: Enum.any?(list, &holds?(&1, key))
  defp holds?(tuple, key) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> holds?(key)
  defp holds?(_leaf, _key), do: false

  defp cut_after_failure(%{best: %{step: {_lane, _slot} = step, plan: plan}} = state) do
    later = run_after(step, plan.journal)

    if Enum.all?(later, &(entries(state)[{&1, :pick}] == {:empty})),
      do: {false, state},
      else: state |> emptied(later) |> attempt(state)
  end

  defp cut_after_failure(state), do: {false, state}

  # The slots that run after `step`: the later slots of its lane and, after
  # a prefix step, every lane slot. A lane step's other lane is left alone,
  # since its later slots may have run before the failure.
  defp run_after({0, failing}, journal) do
    prefix = for slot <- (failing + 1)..journal.max_steps//1, do: {0, slot}
    prefix ++ for lane <- lane_numbers(journal), slot <- lane_slots(journal), do: {lane, slot}
  end

  defp run_after({lane, failing}, journal),
    do: for(slot <- lane_slots(journal), slot > failing, do: {lane, slot})

  defp lane_numbers(%{lanes: nil}), do: []
  defp lane_numbers(_journal), do: [1, 2]

  defp lane_slots(%{lanes: nil}), do: []
  defp lane_slots(%{lanes: %{steps: steps}}), do: 1..steps//1

  defp remove_blocks(state) do
    live = length(state.best.plan.steps)

    live
    |> div(2)
    |> Stream.iterate(&div(&1, 2))
    |> Enum.take_while(&(&1 >= 1))
    |> then(fn sizes -> if sizes == [], do: [1], else: sizes end)
    |> Enum.reduce({false, state}, fn size, {any?, state} ->
      {removed?, state} =
        if size == 1, do: until_stable(state, false), else: block_pass(state, size, 0, false)

      {any? or removed?, state}
    end)
  end

  defp until_stable(state, any?) do
    case block_pass(state, 1, 0, false) do
      {true, state} -> until_stable(state, true)
      {false, state} -> {any?, state}
    end
  end

  defp block_pass(state, size, from, any?) do
    live = Enum.map(state.best.plan.steps, & &1.key)

    if from >= length(live) do
      {any?, state}
    else
      case state |> emptied(Enum.slice(live, from, size)) |> attempt(state) do
        {true, state} -> block_pass(state, size, from, true)
        {false, state} -> block_pass(state, size, from + size, any?)
      end
    end
  end

  # --- Pass 3a: the values that must keep their stored value

  # Answers `{adopted?, kept values, state}`. QuickXplain over the values,
  # with "set to its minimum" as the removal, finds a set to keep that no
  # smaller part of keeps the failure; its first test is the candidate with
  # every value at its minimum. Every candidate is built from the journal
  # held when the phase starts and judged against the failure held then,
  # under `kept_search`:
  #
  #   * `base` - the best failure when the phase started
  #   * `values` - the values, in draw order
  #   * `memo` - the answer for each set of kept values tried
  #   * `runs` - the answer for each plan executed, by its steps and schedule
  #   * `fewest` - the failing candidate with the fewest kept values so far
  #
  # When no candidate fails the same way, every value is kept, so pass 3b
  # bisects each of them.
  defp find_kept(state) do
    case minimizable(state) do
      [] ->
        {false, [], state}

      values ->
        search = %{base: state.best, values: values, memo: %{}, runs: %{}, fewest: nil}
        {kept, state} = quick_xplain(%{state | kept_search: search}, [], true, values)
        {_fails?, state} = fails_kept?(state, kept)
        %{memo: memo, fewest: fewest} = state.kept_search
        state = %{state | kept_search: nil}

        case {memo[MapSet.new(kept)], fewest} do
          {{:failed, failure}, _fewest} -> {true, kept, %{state | best: failure}}
          {:same, _fewest} -> {false, kept, state}
          {_refused, nil} -> {false, values, state}
          {_refused, {smaller, failure}} -> {true, smaller, %{state | best: failure}}
        end
    end
  end

  # When the run budget ends inside pass 3a, its failing candidate with the
  # fewest kept values is adopted.
  defp adopt_fewest_kept(%{kept_search: %{fewest: {_kept, failure}}} = state),
    do: %{state | best: failure, kept_search: nil}

  defp adopt_fewest_kept(state), do: state

  # QuickXplain: `base` is kept in every candidate below this call, and the
  # answer is the part of `candidates` that must be kept too. `test?` says
  # whether the candidate keeping `base` alone is still to be tried.
  defp quick_xplain(state, base, test?, candidates) do
    {fails?, state} = if test?, do: fails_kept?(state, base), else: {false, state}

    cond do
      fails? ->
        {[], state}

      length(candidates) == 1 ->
        {candidates, state}

      true ->
        {first, second} = Enum.split(candidates, div(length(candidates), 2))
        {kept_second, state} = quick_xplain(state, base ++ first, first != [], second)
        {kept_first, state} = quick_xplain(state, base ++ kept_second, kept_second != [], first)
        {kept_first ++ kept_second, state}
    end
  end

  # Whether the candidate that keeps `kept` and puts every other value at
  # its minimum fails the same way. A candidate that rebuilds the plan held
  # does, and costs no run.
  defp fails_kept?(state, kept) do
    set = MapSet.new(kept)

    {result, state} =
      case state.kept_search.memo[set] do
        nil ->
          {result, state} = judge_kept(state, set)
          {result, put_search(state, :memo, set, result)}

        result ->
          {result, state}
      end

    {result == :same or match?({:failed, _}, result), state}
  end

  # Answers `{:failed, failure}`, `:same`, `:passed` (which includes a
  # failure of another kind or at a later step) or `:refused` (the journal
  # cannot be rebuilt).
  defp judge_kept(%{kept_search: search} = state, set) do
    lowered = Enum.reject(search.values, &MapSet.member?(set, &1))
    entries = Enum.reduce(lowered, search.base.plan.journal.entries, &at_minimum(&2, &1))
    journal = %{search.base.plan.journal | entries: entries}

    case rebuild(state, journal) do
      :error ->
        {:refused, state}

      {:ok, plan, drawn} ->
        cond do
          same_plan?(plan, search.base.plan) ->
            {:same, state}

          Map.has_key?(search.runs, plan_id(plan)) ->
            {search.runs[plan_id(plan)], state}

          true ->
            {result, state} = executed_kept(state, plan, drawn)
            {result, state} = retry_kept(state, journal, plan, result)
            state = put_search(state, :runs, plan_id(plan), result)
            {result, note_fewest(state, set, result)}
        end
    end
  end

  # A candidate of the phase that does not fail the same way, with a kept
  # integer that sat on a bound of its stored range that moved, is tried
  # once more with each such integer at its new bound, as `retry/4` does
  # for a single edit.
  defp retry_kept(state, journal, plan, :passed) do
    moved = moved_integers(journal, plan)
    retried = %{plan.journal | entries: Map.merge(plan.journal.entries, moved)}

    with false <- moved == %{},
         {:ok, again, drawn} <- rebuild(state, retried),
         false <- same_plan?(again, state.kept_search.base.plan) do
      case state.kept_search.runs[plan_id(again)] do
        nil ->
          {result, state} = executed_kept(state, again, drawn)
          {result, put_search(state, :runs, plan_id(again), result)}

        seen ->
          {seen, state}
      end
    else
      _no_retry -> {:passed, state}
    end
  end

  defp retry_kept(state, _journal, _plan, result), do: {result, state}

  defp executed_kept(state, plan, drawn) do
    {result, state} = executed(state, plan)

    case result do
      {:error, step, reason} = failed ->
        if same_way?(failed, state.kept_search.base),
          do: {{:failed, %{plan: plan, drawn: drawn, step: step, reason: reason}}, state},
          else: {:passed, state}

      _passed ->
        {:passed, state}
    end
  end

  defp note_fewest(state, set, {:failed, failure}) do
    kept = Enum.filter(state.kept_search.values, &MapSet.member?(set, &1))

    case state.kept_search.fewest do
      {held, _failure} when length(held) <= length(kept) -> state
      _none_or_more -> %{state | kept_search: %{state.kept_search | fewest: {kept, failure}}}
    end
  end

  defp note_fewest(state, _set, _result), do: state

  defp put_search(%{kept_search: search} = state, field, key, value),
    do: %{state | kept_search: Map.update!(search, field, &Map.put(&1, key, value))}

  # The values of pass 3a, in draw order: each integer entry above its
  # range's first value, each member above index 0, and each recorded
  # position of a source entry above its lower bound. StreamData values
  # are left to pass 3c.
  defp minimizable(state) do
    Enum.flat_map(state.best.drawn, fn key ->
      case entries(state)[key] do
        {:integer, value, range} when value > range.first ->
          [{:entry, key}]

        {:member, _value, index} when is_integer(index) and index > 0 ->
          [{:member, key}]

        {@source, _value, _positions} = entry ->
          for {position, {value, lo, _hi}} <- StreamDataSource.positions(entry),
              value > lo,
              do: {:position, key, position}

        _other ->
          []
      end
    end)
  end

  defp at_minimum(entries, {:entry, key}) do
    {:integer, _value, range} = entries[key]
    Map.put(entries, key, {:integer, range.first, range})
  end

  defp at_minimum(entries, {:member, key}), do: Map.put(entries, key, {:member, @no_member, 0})

  defp at_minimum(entries, {:position, key, position}) do
    entry = entries[key]
    {^position, {_value, lo, _hi}} = List.keyfind(StreamDataSource.positions(entry), position, 0)
    Map.put(entries, key, StreamDataSource.put_position(entry, position, lo))
  end

  # --- Pass 3b: bisect each kept value

  # Each kept value, later slots first and in the reverse of the draw order,
  # bisects between its minimum, which pass 3a tried, and its stored value.
  # Each value is read again first, since an adoption can drop it.
  defp narrow(state, kept) do
    kept
    |> Enum.reverse()
    |> Enum.reduce({false, state}, fn value, {any?, state} ->
      {lowered?, state} = narrow_value(state, value)
      {any? or lowered?, state}
    end)
  end

  defp narrow_value(state, {:entry, key} = value) do
    case entries(state)[key] do
      {:integer, stored, range} when stored > range.first ->
        alone(state, value, &bisect(&1, key, range.first, stored, false))

      _other ->
        {false, state}
    end
  end

  defp narrow_value(state, {:member, key}) do
    case entries(state)[key] do
      {:member, _value, index} when is_integer(index) and index > 0 ->
        bisect_member(state, key, 0, index, false)

      _other ->
        {false, state}
    end
  end

  defp narrow_value(state, {:position, key, position} = value) do
    case position_at(state, key, position) do
      {stored, lo, _hi} when stored > lo ->
        alone(state, value, &bisect_position(&1, key, position, lo, stored, false))

      _absent_or_lowest ->
        {false, state}
    end
  end

  defp bisect_member(state, _key, passing, failing, any?) when failing - passing <= 1,
    do: {any?, state}

  defp bisect_member(state, key, passing, failing, any?) do
    middle = div(passing + failing, 2)

    case entries(state)[key] do
      {:member, _value, index} when is_integer(index) ->
        case state |> edited(key, {:member, @no_member, middle}) |> attempt(state) do
          {true, state} -> bisect_member(state, key, passing, middle, true)
          {false, state} -> bisect_member(state, key, middle, failing, any?)
        end

      _changed ->
        {any?, state}
    end
  end

  # --- Pass 3c: StreamData values

  # Each StreamData value walks its shrink tree, later slots first. The list
  # of keys is read again after every adoption, since a rebuild can add or
  # drop keys.
  defp walk_trees(state, done \\ MapSet.new(), any? \\ false) do
    case state.best.drawn |> Enum.reverse() |> Enum.find(&(not MapSet.member?(done, &1))) do
      nil ->
        {any?, state}

      key ->
        {walked?, state} =
          case entries(state)[key] do
            {:stream_data, value, path} when is_list(path) ->
              descend(state, key, value, path, 0, false)

            _other ->
              {false, state}
          end

        walk_trees(state, MapSet.put(done, key), any? or walked?)
    end
  end

  # Bisects between a value known not to fail the same way and one known
  # to fail, stopping when they are adjacent.
  defp bisect(state, _key, passing, failing, any?) when failing - passing <= 1, do: {any?, state}

  defp bisect(state, key, passing, failing, any?) do
    middle = Integer.floor_div(passing + failing, 2)

    with {:integer, _value, range} <- entries(state)[key],
         true <- middle in range do
      case state |> edited(key, {:integer, middle, range}) |> attempt(state) do
        {true, state} -> bisect(state, key, passing, middle, true)
        {false, state} -> bisect(state, key, middle, failing, any?)
      end
    else
      _changed -> {any?, state}
    end
  end

  defp bisect_position(state, _key, _position, passing, failing, any?)
       when failing - passing <= 1,
       do: {any?, state}

  defp bisect_position(state, key, position, passing, failing, any?) do
    middle = Integer.floor_div(passing + failing, 2)

    with {_value, lo, hi} <- position_at(state, key, position),
         true <- middle in lo..hi//1 do
      case state |> edited_position(key, position, middle) |> attempt(state) do
        {true, state} -> bisect_position(state, key, position, passing, middle, true)
        {false, state} -> bisect_position(state, key, position, middle, failing, any?)
      end
    else
      _changed -> {any?, state}
    end
  end

  defp position_at(state, key, position) do
    with {@source, _value, _positions} = entry <- entries(state)[key],
         {^position, drawn} <- List.keyfind(StreamDataSource.positions(entry), position, 0) do
      drawn
    else
      _absent -> nil
    end
  end

  defp edited_position(state, key, position, value),
    do: edited(state, key, StreamDataSource.put_position(entries(state)[key], position, value))

  # Runs the single lowering of one lowerable value (see `lowerable_values/1`)
  # and notes, under `alone`, whether every candidate it made rebuilt the
  # plan already held (`:same`) or one was executed or could not be rebuilt
  # (`:moved`). The pass of pairs reads the notes of the round just ended.
  defp alone(state, value, lower) do
    {lowered?, state} = lower.(%{state | lowering: value})
    {lowered?, %{state | lowering: nil}}
  end

  defp noted(%{lowering: nil} = state, _seen), do: state

  defp noted(%{lowering: value, alone: alone} = state, seen),
    do: %{state | alone: Map.update(alone, value, seen, &merge_seen(&1, seen))}

  defp merge_seen(:moved, _seen), do: :moved
  defp merge_seen(_same, seen), do: seen

  # Lowers pairs of values by the same amount, for a failure that needs two
  # values to fall together. The pairs come from the lowerable values in
  # draw order (see `lowerable_values/1`), and are tried in the order
  # (first, second), (first, third), ..., (second, third), and so on. The
  # first pair kept ends the pass, so the next round reads the pairs again
  # from the rebuilt journal.
  #
  # A value whose single lowering, in the round just ended, rebuilt only the
  # plan already held is left out: it changed nothing alone, so a pair with
  # it would in effect lower the other value alone, the move of pass 3. The
  # round adopted nothing, so its notes describe the plan held now, and
  # reading them costs no run.
  defp lower_pairs(state) do
    values = state |> lowerable_values() |> Enum.reject(&(state.alone[&1] == :same))
    pairs = for [a | rest] <- tails(values), b <- rest, do: {a, b}

    Enum.reduce_while(pairs, {false, state}, fn pair, {false, state} ->
      case lower_pair(state, pair) do
        {true, state} -> {:halt, {true, state}}
        {false, state} -> {:cont, {false, state}}
      end
    end)
  end

  defp tails([]), do: []
  defp tails([_ | rest] = keys), do: [keys | tails(rest)]

  # The largest amount both values can fall first, then bisection between
  # zero, which fails, and the smallest amount known not to fail the same
  # way, for the largest amount that still does.
  defp lower_pair(state, {a, b} = pair) do
    with {va, first_a} <- lowerable(state, a),
         {vb, first_b} <- lowerable(state, b) do
      most = min(va - first_a, vb - first_b)

      case lowered_by(state, pair, {va, vb}, most) do
        {true, state} -> {true, state}
        {false, state} -> bisect_pair(state, pair, {va, vb}, 0, most, false)
      end
    else
      nil -> {false, state}
    end
  end

  defp bisect_pair(state, _pair, _values, kept, refused, any?) when refused - kept <= 1,
    do: {any?, state}

  defp bisect_pair(state, pair, values, kept, refused, any?) do
    middle = div(kept + refused, 2)

    case lowered_by(state, pair, values, middle) do
      {true, state} -> bisect_pair(state, pair, values, middle, refused, true)
      {false, state} -> bisect_pair(state, pair, values, kept, middle, any?)
    end
  end

  # The candidate with both values `amount` below `values`. Both values are
  # read again first, since a kept candidate can drop a key or a position,
  # or move a range; a value outside its current range is not tried.
  defp lowered_by(state, {a, b}, {va, vb}, amount) do
    journal = state.best.plan.journal

    with %{} = entries <- put_value(journal.entries, a, va - amount),
         %{} = entries <- put_value(entries, b, vb - amount) do
      attempt(%{journal | entries: entries}, state)
    else
      nil -> {false, state}
    end
  end

  # The values a pair can lower, in draw order: each integer entry above its
  # range's first value, as `{:entry, key}`, and each recorded position of a
  # source entry above its lower bound, as `{:position, key, position}`, in
  # the entry's draw order. Two positions of one entry can form a pair, for
  # a relation inside one nested value.
  defp lowerable_values(state) do
    Enum.flat_map(state.best.drawn, fn key ->
      case entries(state)[key] do
        {:integer, value, range} when value > range.first ->
          [{:entry, key}]

        {@source, _value, _positions} = entry ->
          for {position, {value, lo, _hi}} <- StreamDataSource.positions(entry),
              value > lo,
              do: {:position, key, position}

        _other ->
          []
      end
    end)
  end

  # A lowerable value as `{value, lower bound}`, or nil once it is gone or
  # sits on its lower bound.
  defp lowerable(state, {:entry, key}) do
    case entries(state)[key] do
      {:integer, value, range} when value > range.first -> {value, range.first}
      _other -> nil
    end
  end

  defp lowerable(state, {:position, key, position}) do
    case position_at(state, key, position) do
      {value, lo, _hi} when value > lo -> {value, lo}
      _other -> nil
    end
  end

  # `entries` with the lowerable value set to `new`, or nil when the value
  # is gone or `new` falls outside its current range. A position keeps its
  # recorded bounds.
  defp put_value(entries, {:entry, key}, new) do
    case entries[key] do
      {:integer, _value, range} ->
        if new in range, do: Map.put(entries, key, {:integer, new, range})

      _other ->
        nil
    end
  end

  defp put_value(entries, {:position, key, position}, new) do
    with {@source, _value, _positions} = entry <- entries[key],
         {^position, {_stored, lo, hi}} <-
           List.keyfind(StreamDataSource.positions(entry), position, 0),
         true <- new in lo..hi//1 do
      Map.put(entries, key, StreamDataSource.put_position(entry, position, new))
    else
      _gone_or_outside -> nil
    end
  end

  defp first_adopted(state, candidates, edit) do
    Enum.reduce_while(candidates, {false, state}, fn candidate, {false, state} ->
      case state |> edit.(candidate) |> attempt(state) do
        {true, state} -> {:halt, {true, state}}
        {false, state} -> {:cont, {false, state}}
      end
    end)
  end

  # Tries the children of the node at `path` in order; on the first one
  # adopted, goes on from its own children. A child index past the node's
  # last child walks back to the node itself, which ends the search here.
  defp descend(state, key, value, path, index, any?) do
    child = path ++ [index]
    reaches_child? = fn %Plan{journal: journal} -> path_at(journal, key) == child end

    case state |> edited(key, {:stream_data, value, child}) |> attempt(state, reaches_child?) do
      {true, state} -> descend(state, key, value, child, 0, true)
      {false, state} -> descend(state, key, value, path, index + 1, any?)
      {:skipped, state} -> {any?, state}
    end
  end

  defp path_at(journal, key) do
    case journal.entries[key] do
      {:stream_data, _value, path} -> path
      _other -> nil
    end
  end

  # --- Candidates

  defp entries(state), do: state.best.plan.journal.entries

  defp edited(state, key, entry) do
    journal = state.best.plan.journal
    %{journal | entries: Map.put(journal.entries, key, entry)}
  end

  defp emptied(state, steps) do
    journal = state.best.plan.journal
    %{journal | entries: Enum.reduce(steps, journal.entries, &Map.put(&2, {&1, :pick}, {:empty}))}
  end

  # Rebuilds and executes one candidate journal. Answers `{true, state}`
  # when it was adopted and `{false, state}` when not.
  defp attempt(journal, state) do
    case attempt(journal, state, fn _plan -> true end) do
      {:skipped, state} -> {false, state}
      answer -> answer
    end
  end

  # As attempt/2, but answers `{:skipped, state}`, executing nothing, when
  # the journal cannot be rebuilt or `wanted?` refuses the rebuilt plan.
  defp attempt(journal, state, wanted?) do
    case rebuild(state, journal) do
      {:ok, plan, drawn} ->
        cond do
          not wanted?.(plan) -> {:skipped, state}
          same_plan?(plan, state.best.plan) -> {false, noted(state, :same)}
          true -> judge(noted(state, :moved), journal, plan, drawn, true)
        end

      :error ->
        {:skipped, noted(state, :moved)}
    end
  end

  defp judge(state, journal, plan, drawn, retry?) do
    {result, state} = executed(state, plan)

    case result do
      {:error, step, reason} = failed ->
        if same_way?(failed, state.best),
          do: {true, %{state | best: %{plan: plan, drawn: drawn, step: step, reason: reason}}},
          else: retry(state, journal, plan, retry?)

      _passed ->
        retry(state, journal, plan, retry?)
    end
  end

  # A stored integer kept although its stored range's bound that it sat on
  # moved: the candidate with each such value at its new bound, tried once.
  defp retry(state, _journal, _plan, false), do: {false, state}

  defp retry(state, journal, plan, true) do
    moved = moved_integers(journal, plan)

    if moved == %{} do
      {false, state}
    else
      retried = %{plan.journal | entries: Map.merge(plan.journal.entries, moved)}

      with {:ok, again, drawn} <- rebuild(state, retried),
           false <- same_plan?(again, state.best.plan) do
        judge(state, retried, again, drawn, false)
      else
        _same_or_error -> {false, state}
      end
    end
  end

  # Each integer of `plan` that `journal` stored on a bound of its stored
  # range and that the rebuild kept although that bound moved, at the new
  # bound.
  defp moved_integers(journal, plan) do
    for {key, {:integer, value, range}} <- plan.journal.entries,
        {:integer, ^value, stored} <- [journal.entries[key]],
        bound = moved_bound(value, stored, range),
        bound != nil,
        into: %{},
        do: {key, {:integer, bound, range}}
  end

  # The execution of `plan`: the one the round already made of the same
  # plan, or a new one, which spends a run.
  defp executed(state, plan) do
    case Map.fetch(state.ran, plan_id(plan)) do
      {:ok, result} ->
        {result, state}

      :error ->
        state = spend(state)
        result = state.execute.(plan)
        {result, %{state | ran: Map.put(state.ran, plan_id(plan), result)}}
    end
  end

  defp plan_id(plan), do: {plan.steps, plan.schedule}

  # A plan is the test case already held when its steps and its schedule
  # are those of `best`.
  defp same_plan?(plan, best), do: plan.steps == best.steps and plan.schedule == best.schedule

  defp moved_bound(value, %Range{} = stored, range) do
    cond do
      value == stored.first and range.first != stored.first -> range.first
      value == stored.last and range.last != stored.last -> range.last
      true -> nil
    end
  end

  defp moved_bound(_value, _stored, _range), do: nil

  defp rebuild(state, journal) do
    {plan, drawn} = state.build.(journal)
    {:ok, plan, drawn}
  rescue
    # Raise mode stops the whole run at a dependent StreamData generator,
    # in a candidate as in the plan that failed first.
    exception in PropertyDamage.Next.DependentStreamDataError ->
      reraise exception, __STACKTRACE__

    # An edited journal can give a model a value its own code refuses; such
    # a candidate is dropped, not executed.
    _exception ->
      :error
  end

  defp spend(%{runs: runs, limit: limit} = state) when runs >= limit,
    do: throw({__MODULE__, :spent, state})

  defp spend(state), do: %{state | runs: state.runs + 1}

  # --- Failing the same way

  defp same_way?({:error, step, reason}, best),
    do: class(reason) == class(best.reason) and not later?(step, best.step)

  defp later?(step, step), do: false
  defp later?({lane, slot}, {lane, best}), do: slot > best
  # A prefix step runs before every lane step.
  defp later?({0, _slot}, {_lane, _best}), do: false
  # Steps of the two lanes compare by slot.
  defp later?({_lane, slot}, {other, best}) when other != 0, do: slot > best
  defp later?(_step, _best), do: true

  # The kind of a failure: the check that failed, the adapter's error
  # reason (its tag when it is a tagged tuple), or the exception's module.
  defp class({:check, name, _message}), do: {:check, name}
  defp class({:adapter_error, reason}), do: {:adapter_error, error_class(reason)}
  defp class({:raise, %module{}}), do: {:raise, module}
  # A divergence is classed by its observation name: two divergences of one
  # observation are the same failure whatever values the executions saw.
  defp class({:diverged, name, _step, _reference, _variant}), do: {:diverged, name}
  defp class(other), do: other

  defp error_class(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: elem(tuple, 0)

  defp error_class(reason), do: reason

  # --- The final journal

  defp finish(state) do
    %{best: best} = state
    withdrawn = MapSet.new(best.plan.withdrawn, & &1.key)

    entries =
      Enum.reduce(best.plan.journal.entries, %{}, fn {key, entry}, entries ->
        cond do
          not MapSet.member?(withdrawn, elem(key, 0)) -> Map.put(entries, key, entry)
          match?({_step, :pick}, key) -> Map.put(entries, key, {:empty})
          true -> entries
        end
      end)

    journal = %{best.plan.journal | entries: entries}
    {plan, drawn} = state.build.(journal)
    runs = state.runs + 1

    final =
      case state.execute.(plan) do
        {:error, step, reason} = failed ->
          if same_way?(failed, best),
            do: %{plan: plan, drawn: drawn, step: step, reason: reason},
            else: best

        _passed ->
          best
      end

    {final, runs}
  end
end
