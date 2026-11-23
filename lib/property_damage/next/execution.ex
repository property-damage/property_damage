defmodule PropertyDamage.Next.Execution do
  @moduledoc false
  # Executes one plan against the system under test: the adapter's setup,
  # one `execute/3` per step in slot order, the checks after each step, and
  # the adapter's teardown.
  #
  # A step is one or more points. Its first point is its call to
  # `execute/3`; each `{:yield, continuation}` it answers adds one, the next
  # point being the call to that continuation, and the step completes at
  # the point that answers `{:ok, events}`. In a plan with one lane, and in
  # the prefix of a plan with two, each continuation is called at once.
  # The two lanes run after the prefix, in one process: at each turn the
  # plan's schedule picks the lane whose next point runs (see
  # `PropertyDamage.Next.Plan`). A lane step may yield at most `yields`
  # times. A step's events fold, and the checks run, when it completes, so
  # steps of two lanes fold in the order they complete.
  #
  # Before a step reaches the adapter, its command and assigns are made
  # concrete. A placeholder becomes the value the system minted: the field at
  # the placeholder's path in the real event at its index, among the events
  # its step returned. A mint marker becomes a value derived from a nonce
  # drawn once per execution and from the marker's stamp, the step and
  # field generation drew it for, so every step that holds one marker sends
  # one value, and every execution, a replay of the same journal included,
  # sends values no earlier execution sent. A marker without a stamp is
  # given one from where it sits in the step. The adapter receives neither
  # kind of marker, nor a step, a slot or a journal key.
  #
  # The execution stops at the first step that fails: the adapter answers
  # `{:error, reason}`, raises, exits or throws, a check fails, or a value
  # cannot be made concrete. A step the other lane left open is dropped
  # then, and its continuation is never called.
  #
  # A model that states paths runs the plan twice, in lockstep, against two
  # setups of the adapter: the reference, set up first, and the variant.
  # Each has its own context, its own checks and its own nonce. At each step
  # the reference runs the step's command; then the variant runs each
  # command of the step's path in order (the step's command for a step
  # without a path), each its own call to `execute/3` with the step's
  # assigns, folded and checked as a step is. The variant's events for the
  # step are those of its commands in order, so a later placeholder naming
  # the step resolves against them. Then the `@compare` observations judge
  # the two executions, each given the step's command made concrete in that
  # execution. The plans of such a model have one lane.

  require Logger

  alias PropertyDamage.Mint

  alias PropertyDamage.Next.{
    AcknowledgedIgnoredAssignError,
    AcknowledgedUnsetAssignError,
    AssignCounts,
    Checks,
    Placeholder,
    Plan,
    Runtime,
    Step
  }

  @type reason ::
          {:check, atom(), String.t()}
          | {:adapter_error, term()}
          | {:raise, Exception.t()}
          | {:diverged, atom(), term(), term(), term()}

  @doc """
  Executes `plan`. Returns `:ok`, or `{:error, step_key, reason}` for the
  first failing step; a failing setup has `nil` as its step key.

  Options: `:ignored` lists the assign keys the adapter's target ignores
  (default `[]`), and `:counts` is an `AssignCounts` table that receives the
  assigns the steps set and the adapter acknowledges (default `nil`: none
  counted). The adapter's acknowledgments are checked either way, and the
  two errors they can raise leave this function as raises. `paths: true`
  runs the plan twice, the reference and the variant, and compares them
  after each step (default `false`); a failing setup of either has `nil` as
  its step key, and every context set up is torn down.
  """
  @spec run(Plan.t(), module(), term(), [module()], keyword()) ::
          :ok | {:error, term(), reason()}
  def run(%Plan{} = plan, adapter, config, projections, opts \\ []) do
    checks = Checks.init(projections)

    with_context(adapter, config, fn context ->
      run = open(adapter, context, checks, opts)

      if Keyword.get(opts, :paths, false) do
        with_context(adapter, config, fn variant_context ->
          lockstep(plan.steps, run, open(adapter, variant_context, checks, opts))
        end)
      else
        execute(plan, run)
      end
    end)
  end

  # Calls `fun` with a context the adapter set up, and tears it down after.
  defp with_context(adapter, config, fun) do
    case setup(adapter, config) do
      {:ok, context} ->
        try do
          fun.(context)
        after
          teardown(adapter, context)
        end

      {:error, reason} ->
        {:error, nil, reason}
    end
  end

  # One execution: its own context, checks, nonce and the events its steps
  # returned.
  defp open(adapter, context, checks, opts) do
    %{
      adapter: adapter,
      context: context,
      nonce: nonce(),
      events: %{},
      checks: checks,
      ignored: Keyword.get(opts, :ignored, []),
      counts: Keyword.get(opts, :counts)
    }
  end

  defp nonce, do: 8 |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned()

  # --- The adapter's lifecycle

  defp setup(adapter, config) do
    case adapter.setup(config, %Runtime{}) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:adapter_error, reason}}
      other -> {:error, {:raise, bad_return(adapter, "setup/2", "{:ok, context}", other)}}
    end
  rescue
    exception -> {:error, {:raise, exception}}
  catch
    kind, reason -> {:error, {:raise, caught(kind, reason)}}
  end

  # Teardown is best effort: a teardown that fails is logged and never
  # changes the result of the execution.
  defp teardown(adapter, context) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :teardown, 1),
      do: adapter.teardown(context)

    :ok
  rescue
    exception -> log_teardown(adapter, Exception.message(exception))
  catch
    kind, reason -> log_teardown(adapter, Exception.message(caught(kind, reason)))
  end

  defp log_teardown(adapter, message) do
    Logger.warning("#{inspect(adapter)}.teardown/1 failed: #{message}")
    :ok
  end

  # --- The steps

  defp execute(%Plan{steps: steps, schedule: schedule, journal: journal}, run) do
    {prefix, lane_one, lane_two} = split(steps)

    with {:ok, run} <- prefix(prefix, run) do
      yields = if journal.lanes, do: journal.lanes.yields, else: 0
      lanes = %{1 => {lane_one, nil}, 2 => {lane_two, nil}}
      interleave(lanes, run, %{schedule: schedule, yields: yields})
    end
  end

  defp split(steps) do
    lane = fn n -> Enum.filter(steps, &match?(%Step{key: {^n, _slot}}, &1)) end
    {lane.(0), lane.(1), lane.(2)}
  end

  # Prefix steps run one after another, each driven to completion.
  defp prefix([], run), do: {:ok, run}

  defp prefix([step | rest], run) do
    case drive(start(step, run), run) do
      {:ok, run} -> prefix(rest, run)
      {:error, key, reason} -> {:error, key, reason}
    end
  end

  # --- Two executions in lockstep

  defp lockstep([], _reference, _variant), do: :ok

  defp lockstep([step | rest], reference, variant) do
    with {:ok, reference} <- drive(start(step, reference), reference),
         {:ok, variant} <- variant_step(step, variant),
         :ok <- compare(step, reference, variant) do
      lockstep(rest, reference, variant)
    end
  end

  # The variant's commands for `step`, each run as a step of its own under
  # the step's key and with the step's assigns.
  defp variant_step(%Step{path: path, command: command} = step, run) do
    commands =
      case path do
        {_index, commands} -> commands
        nil -> [command]
      end

    Enum.reduce_while(commands, {:ok, run}, fn command, {:ok, run} ->
      case drive(start(%{step | command: command}, run), run) do
        {:ok, run} -> {:cont, {:ok, run}}
        failure -> {:halt, failure}
      end
    end)
  end

  defp compare(%Step{key: key, command: command}, reference, variant) do
    reference_root = concrete(command, key, [:command], reference)
    variant_root = concrete(command, key, [:command], variant)

    case Checks.compare(reference.checks, variant.checks, reference_root, variant_root, key) do
      :ok -> :ok
      {:error, reason} -> {:error, key, reason}
    end
  rescue
    exception -> {:error, key, {:raise, exception}}
  catch
    kind, reason -> {:error, key, {:raise, caught(kind, reason)}}
  end

  defp drive({:open, open}, run), do: drive(continue(open, run), run)
  defp drive({:done, open, events}, run), do: complete(open, events, run)
  defp drive({:error, key, reason}, _run), do: {:error, key, reason}

  # Each lane is `{steps not yet started, open step or nil}`. Lane 1's next
  # point runs once lane 2's next point sits at or after the position the
  # schedule gives that lane-1 point.
  defp interleave(lanes, run, ctx) do
    case {next_point(lanes[1]), next_point(lanes[2])} do
      {nil, nil} -> :ok
      {nil, _point} -> turn(2, lanes, run, ctx)
      {_point, nil} -> turn(1, lanes, run, ctx)
      {one, two} -> turn(if(runs_first?(one, two, ctx), do: 1, else: 2), lanes, run, ctx)
    end
  end

  defp next_point({_steps, %{key: {_lane, slot}, point: point}}), do: {slot, point}
  defp next_point({[%Step{key: {_lane, slot}} | _rest], nil}), do: {slot, 1}
  defp next_point({[], nil}), do: nil

  defp runs_first?({slot, point}, {lane_two_slot, lane_two_point}, ctx) do
    position = (lane_two_slot - 1) * (ctx.yields + 1) + (lane_two_point - 1)
    position >= ctx.schedule |> Map.fetch!({1, slot}) |> Enum.at(point - 1)
  end

  defp turn(lane, lanes, run, ctx) do
    answer =
      case lanes[lane] do
        {steps, nil} -> start(hd(steps), run)
        {_steps, open} -> continue(open, run)
      end

    case answer do
      {:open, %{key: key, point: point}} when point > ctx.yields + 1 ->
        {:error, key, {:raise, too_many_yields(run.adapter, ctx.yields)}}

      {:open, open} ->
        interleave(Map.put(lanes, lane, {rest(lanes[lane]), open}), run, ctx)

      {:done, open, events} ->
        with {:ok, run} <- complete(open, events, run) do
          interleave(Map.put(lanes, lane, {rest(lanes[lane]), nil}), run, ctx)
        end

      {:error, key, reason} ->
        {:error, key, reason}
    end
  end

  # The steps a lane has not started once its next point ran.
  defp rest({[_started | steps], nil}), do: steps
  defp rest({steps, _open}), do: steps

  defp too_many_yields(adapter, yields) do
    %ArgumentError{
      message:
        "#{inspect(adapter)}.execute/3 yielded more than #{yields} times in one step " <>
          "of a lane; raise the :yields option"
    }
  end

  # The first point of a step: its command and assigns made concrete, its
  # scope built, and `execute/3` called within it.
  defp start(%Step{key: key, command: command, assigns: assigns}, run) do
    point(key, fn ->
      command = concrete(command, key, [:command], run)
      assigns = concrete(assigns, key, [:assigns], run)
      scope = scope(run, command, assigns)
      open = %{key: key, command: command, scope: scope, point: 1, continuation: nil}
      answer = Runtime.with_step(scope, fn -> call(run, command, assigns) end)
      {open, answer}
    end)
  end

  # A later point: the open step's continuation, called within its scope.
  defp continue(%{key: key, scope: scope, continuation: continuation} = open, run) do
    point(key, fn ->
      answer = Runtime.with_step(scope, fn -> answer(run.adapter, continuation.()) end)
      {open, answer}
    end)
  end

  # Runs point `open.point` of a step. Answers `{:open, open}` for a step
  # that yielded, with `point` now the number of the point to come,
  # `{:done, open, events}` for a step that completed, or
  # `{:error, key, reason}`.
  defp point(key, fun) do
    case fun.() do
      {open, {:yield, continuation}} ->
        {:open, %{open | continuation: continuation, point: open.point + 1}}

      {open, {:ok, events}} ->
        {:done, open, events}

      {_open, {:error, reason}} ->
        {:error, key, reason}
    end
  rescue
    # Misuse of an acknowledgment is not a failure of the system under test.
    exception in [AcknowledgedUnsetAssignError, AcknowledgedIgnoredAssignError] ->
      reraise exception, __STACKTRACE__

    exception ->
      {:error, key, {:raise, exception}}
  catch
    kind, reason -> {:error, key, {:raise, caught(kind, reason)}}
  end

  # A completed step: its events stored for the placeholders that name
  # them, then folded and checked. A variant's later command of the same
  # step appends its events to those stored under the step.
  defp complete(%{key: key, command: command}, events, run) do
    case Checks.step(run.checks, command, events) do
      {:ok, checks} ->
        stored = Map.update(run.events, key, events, &(&1 ++ events))
        {:ok, %{run | events: stored, checks: checks}}

      {:error, reason} ->
        {:error, key, reason}
    end
  rescue
    exception -> {:error, key, {:raise, exception}}
  catch
    kind, reason -> {:error, key, {:raise, caught(kind, reason)}}
  end

  # The running step as `Runtime.ack/2` sees it, with the step's set
  # assigns counted: an assign is set when its drawn value is truthy.
  defp scope(run, command, assigns) do
    module = command.__struct__
    set = for {key, value} <- assigns, value, do: key

    if run.counts,
      do: Enum.each(set, &AssignCounts.record_set(run.counts, run.adapter, module, &1))

    %{
      target: run.adapter,
      command: module,
      set: set,
      ignored: run.ignored,
      counts: run.counts
    }
  end

  defp call(%{adapter: adapter, context: context}, command, assigns) do
    case adapter.execute(command, assigns, context) do
      {:ok, events} when is_list(events) -> {:ok, events}
      {:yield, continuation} when is_function(continuation, 0) -> {:yield, continuation}
      {:error, reason} -> {:error, {:adapter_error, reason}}
      other -> raise bad_answer("#{inspect(adapter)}.execute/3", other)
    end
  end

  # What a continuation answered, read as an answer of `execute/3`.
  defp answer(adapter, answer) do
    case answer do
      {:ok, events} when is_list(events) -> {:ok, events}
      {:yield, continuation} when is_function(continuation, 0) -> {:yield, continuation}
      {:error, reason} -> {:error, {:adapter_error, reason}}
      other -> raise bad_answer("a continuation of #{inspect(adapter)}.execute/3", other)
    end
  end

  defp bad_answer(function, got) do
    %ArgumentError{
      message:
        "#{function} must return {:ok, events}, {:yield, continuation} or {:error, reason}, " <>
          "got: #{inspect(got)}"
    }
  end

  defp bad_return(adapter, function, expected, got) do
    %ArgumentError{
      message:
        "#{inspect(adapter)}.#{function} must return #{expected} or {:error, reason}, " <>
          "got: #{inspect(got)}"
    }
  end

  # An exit or a throw out of user code, as an exception.
  defp caught(kind, reason), do: %ErlangError{original: {kind, reason}}

  # --- Concrete values

  # `path` is where the term sits in the step, innermost first.
  defp concrete(%Placeholder{} = placeholder, _key, _path, run),
    do: resolve(placeholder, run.events)

  defp concrete(%Mint{position: nil} = marker, key, path, run),
    do: marker |> Mint.reify(key, Enum.reverse(path)) |> Mint.resolve(run.nonce, 0)

  defp concrete(%Mint{} = marker, _key, _path, run), do: Mint.resolve(marker, run.nonce, 0)

  defp concrete(%_{} = struct, key, path, run) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(struct, fn {field, value}, acc ->
      Map.put(acc, field, concrete(value, key, [field | path], run))
    end)
  end

  defp concrete(%{} = map, key, path, run) do
    Map.new(map, fn {k, v} ->
      {concrete(k, key, [{:key, k} | path], run), concrete(v, key, [k | path], run)}
    end)
  end

  defp concrete(list, key, path, run) when is_list(list),
    do: concrete_list(list, 0, key, path, run)

  defp concrete(tuple, key, path, run) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> concrete_list(0, key, path, run)
    |> List.to_tuple()
  end

  defp concrete(other, _key, _path, _run), do: other

  defp concrete_list([head | tail], position, key, path, run) do
    [
      concrete(head, key, [position | path], run)
      | concrete_list(tail, position + 1, key, path, run)
    ]
  end

  defp concrete_list(tail, _position, _key, _path, _run), do: tail

  defp resolve(%Placeholder{step: step, event_index: index, path: path}, events) do
    with {:ok, step_events} <- Map.fetch(events, step),
         {:ok, event} <- at(step_events, index),
         {:ok, value} <- dig(event, path) do
      value
    else
      :error ->
        raise ArgumentError,
              "a value the system under test was predicted to mint is missing from its " <>
                "answer: step #{inspect(step)}, event #{index}, field path #{inspect(path)}"
    end
  end

  defp dig(value, []), do: {:ok, value}

  defp dig(%{} = map, [field | rest]) do
    with {:ok, inner} <- Map.fetch(map, field), do: dig(inner, rest)
  end

  defp dig(list, [position | rest]) when is_list(list) and is_integer(position) do
    with {:ok, inner} <- at(list, position), do: dig(inner, rest)
  end

  defp dig(_value, _path), do: :error

  defp at(list, index) when is_list(list) and index >= 0 and index < length(list),
    do: {:ok, Enum.at(list, index)}

  defp at(_list, _index), do: :error
end
