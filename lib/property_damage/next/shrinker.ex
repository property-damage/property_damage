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
  #   3. lower each drawn value, later slots first and, within a slot, in
  #      the reverse of the draw order, so a value drawn from another field
  #      is lowered before the field it depends on. An integer tries its
  #      range's lower bound first, then bisects between it and the stored
  #      value. A member tries each lower index of its list, from 0. A
  #      StreamData value extends its path in the shrink tree, trying the
  #      node's children in order and descending into the first that fails.
  #
  # Slots are withdrawn by generation, not by the shrinker: an edit that
  # leaves a stored pick no longer offered withdraws that slot, which keeps
  # its entries in the rebuilt journal so a later edit can bring it back.
  #
  # A stored integer that sat on a bound of its stored range and was kept
  # although that bound moved is tried at the new bound once, right after
  # the candidate that kept it was not adopted.
  #
  # The final journal drops what the search kept: each withdrawn slot's
  # pick becomes `{:empty}` and its other entries go, so the journal holds
  # exactly its plan's draws. The plan it rebuilds is executed once more,
  # and that execution is the failure returned.
  #
  # Every execution after the plan that first failed counts as a shrink
  # run, the last one included, and there are at most `max_runs` of them.

  alias PropertyDamage.Next.Engine.StreamDataSource
  alias PropertyDamage.Next.{Journal, Plan}

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
  `{:error, step, reason}`. Returns `{best, runs}`.
  """
  @spec shrink(best(), (Journal.t() -> {Plan.t(), [term()]}), (Plan.t() -> term()), pos_integer()) ::
          {best(), non_neg_integer()}
  def shrink(best, build, execute, max_runs) do
    state = %{best: best, build: build, execute: execute, runs: 0, limit: max_runs - 1}

    searched =
      try do
        state |> cut_after_failure() |> elem(1) |> rounds()
      catch
        {__MODULE__, :spent, spent} -> spent
      end

    finish(searched)
  end

  # --- Passes

  defp rounds(state) do
    {removed?, state} = remove_blocks(state)
    {lowered?, state} = lower(state)
    if removed? or lowered?, do: rounds(state), else: state
  end

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

  # Lowers each drawn value once per round. The list of keys is read again
  # after every adoption, since a rebuild can add or drop keys.
  defp lower(state, done \\ MapSet.new(), any? \\ false) do
    case state.best.drawn |> Enum.reverse() |> Enum.find(&(not MapSet.member?(done, &1))) do
      nil ->
        {any?, state}

      key ->
        {lowered?, state} = lower_key(state, key)
        lower(state, MapSet.put(done, key), any? or lowered?)
    end
  end

  defp lower_key(state, key) do
    case entries(state)[key] do
      {:integer, value, range} when value > range.first ->
        case state |> edited(key, {:integer, range.first, range}) |> attempt(state) do
          {true, state} -> {true, state}
          {false, state} -> bisect(state, key, range.first, value, false)
        end

      {:member, _value, index} when is_integer(index) and index > 0 ->
        first_adopted(state, 0..(index - 1)//1, &edited(&1, key, {:member, @no_member, &2}))

      {:stream_data, value, path} when is_list(path) ->
        descend(state, key, value, path, 0, false)

      {@source, _value, _positions} = entry ->
        entry
        |> StreamDataSource.positions()
        |> Enum.reverse()
        |> Enum.reduce({false, state}, fn {position, _drawn}, {any?, state} ->
          {lowered?, state} = lower_position(state, key, position)
          {any? or lowered?, state}
        end)

      _other ->
        {false, state}
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

  # Lowers one recorded position of a source entry: its lower bound first,
  # then bisection between it and the stored value. The position is read
  # again before each candidate, since an adoption can drop it or move its
  # bounds.
  defp lower_position(state, key, position) do
    case position_at(state, key, position) do
      {value, lo, _hi} when value > lo ->
        case state |> edited_position(key, position, lo) |> attempt(state) do
          {true, state} -> {true, state}
          {false, state} -> bisect_position(state, key, position, lo, value, false)
        end

      _absent_or_lowest ->
        {false, state}
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
          same_plan?(plan, state.best.plan) -> {false, state}
          true -> judge(state, journal, plan, drawn, true)
        end

      :error ->
        {:skipped, state}
    end
  end

  defp judge(state, journal, plan, drawn, retry?) do
    state = spend(state)

    case state.execute.(plan) do
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
    moved =
      for {key, {:integer, value, range}} <- plan.journal.entries,
          {:integer, ^value, stored} <- [journal.entries[key]],
          bound = moved_bound(value, stored, range),
          bound != nil,
          into: %{},
          do: {key, {:integer, bound, range}}

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
