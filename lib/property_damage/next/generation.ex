defmodule PropertyDamage.Next.Generation do
  @moduledoc false
  # Builds a plan from a model and a journal, slot by slot, carrying the
  # predicted state.
  #
  # At each slot it keeps the specs whose `when:` holds on the predicted
  # state and picks one: the stored pick if the journal has one and that
  # spec is still offered, a weighted draw from the key's seed if the
  # journal has none. A stored pick no longer offered withdraws the slot:
  # no step, and generation goes on; the slot's entries stay in the rebuilt
  # journal. An empty pick, `{:empty}`, yields no step and draws nothing
  # for its slot; it is written back and withdraws nothing. The picked spec's command fields and
  # assigns are drawn through the engine, each under its own key; then the
  # simulator predicts the command's events and the command-sequence
  # projection folds them into the state the next slot reads.
  #
  # Keys: the step is `{lane, slot}`, with lane 0 for a one-lane plan and
  # slots counted from 1. A draw is `{step, :pick}`,
  # `{step, :command, field}`, `{step, :assigns, key}`, `{step, :path}` or
  # `{step, :path, name}`.
  #
  # For a step whose command module the model lists in expansions/0, the
  # path is drawn after the command's fields and assigns and before the
  # prediction: the paths function gets the command as drawn and the state
  # its generator saw, the pick is a member of the path indexes, and a path
  # that draws values of its own draws each under its name. A model without
  # expansions/0 draws no path key, so its journals are those it had before
  # paths existed.
  #
  # With two lanes, the prefix is lane 0's `max_steps` slots, built as a
  # one-lane plan is. Lane 1 and lane 2 then have `lane_steps` slots each,
  # and each lane starts from the predicted state after the prefix: a lane
  # folds only its own steps' events, so a `when:` in a lane holds when that
  # lane runs alone after the prefix. Once both lanes are built, and only if
  # each holds a step, the schedule is drawn: for each lane-1 step in slot
  # order, one integer per point, `{{1, slot}, :schedule, point}` for points
  # 1 to `yields + 1`, each naming a lane-2 position from 0 to
  # `lane_steps * (yields + 1)`. Drawing it last leaves every key of the
  # prefix and of the lanes drawn as it would be without a schedule.
  #
  # A generator that a from/2 function or a dependent assign returns, when
  # it is not a PD description, reaches the engine wrapped with its site.
  # Unless the engine says it fits such a value, the site goes on the plan's
  # kept list, or, in raise mode, generation raises at its first draw.
  #
  # A mint marker is stamped at its first draw with the step and the
  # location of its key, and a stamped marker keeps its stamp: a marker the
  # model reads back from its predicted state names the step that drew it,
  # so execution gives it the same value there.

  alias PropertyDamage.External
  alias PropertyDamage.Mint
  alias PropertyDamage.Next.Engine.Dependent

  alias PropertyDamage.Next.{
    DependentStreamDataError,
    From,
    Gen,
    GeneratorCheck,
    Journal,
    Model,
    Placeholder,
    Plan,
    Step,
    StepSpec
  }

  alias PropertyDamage.Next.StepSpec.FromCommand

  @prefix 0

  @doc "Builds the plan of `specs` from `journal`."
  @spec build(module(), [StepSpec.t()], Journal.t(), keyword()) :: Plan.t()
  def build(model, specs, journal, opts), do: model |> trace(specs, journal, opts) |> elem(0)

  @doc """
  Builds the plan of `specs` from `journal`, and lists the keys of its
  field and assign draws in the order they were drawn.
  """
  @spec trace(module(), [StepSpec.t()], Journal.t(), keyword()) :: {Plan.t(), [term()]}
  def trace(model, specs, %Journal{} = journal, opts) do
    projection = model.command_sequence_projection()

    acc = %{
      model: model,
      specs: specs,
      engine: Keyword.fetch!(opts, :engine),
      simulator: model.simulator(),
      projection: projection,
      journal: journal,
      state: projection.init(),
      entries: %{},
      steps: [],
      withdrawn: [],
      drawn: [],
      mode: Keyword.get(opts, :dependent_stream_data, :warn),
      kept: [],
      eligible: MapSet.new(),
      expansions: Model.expansions!(model, specs)
    }

    max_steps = Keyword.fetch!(opts, :max_steps)
    acc = Enum.reduce(1..max_steps//1, acc, &slot(@prefix, &1, &2))
    {acc, schedule, lanes} = lanes(acc, opts)

    plan = %Plan{
      steps: Enum.reverse(acc.steps),
      journal: %{journal | entries: acc.entries, max_steps: max_steps, lanes: lanes},
      withdrawn: Enum.reverse(acc.withdrawn),
      kept: Enum.reverse(acc.kept),
      eligible: acc.eligible |> MapSet.to_list() |> Enum.sort(),
      schedule: schedule
    }

    {plan, Enum.reverse(acc.drawn)}
  end

  # --- Lanes

  defp lanes(acc, opts) do
    case Keyword.get(opts, :lanes, 1) do
      1 ->
        {acc, %{}, nil}

      2 ->
        lane_steps = Keyword.fetch!(opts, :lane_steps)
        yields = Keyword.fetch!(opts, :yields)
        forked = acc.state

        acc =
          Enum.reduce([1, 2], acc, fn lane, acc ->
            Enum.reduce(1..lane_steps//1, %{acc | state: forked}, &slot(lane, &1, &2))
          end)

        {acc, schedule} = schedule(acc, lane_steps, yields)
        {acc, schedule, %{count: 2, steps: lane_steps, yields: yields}}
    end
  end

  defp schedule(acc, lane_steps, yields) do
    keys = Enum.map(acc.steps, & &1.key)
    lane_one = keys |> Enum.filter(&match?({1, _slot}, &1)) |> Enum.sort()

    if lane_one == [] or not Enum.any?(keys, &match?({2, _slot}, &1)) do
      {acc, %{}}
    else
      positions = Gen.integer(0..(lane_steps * (yields + 1)))

      Enum.reduce(lane_one, {acc, %{}}, fn step, {acc, schedule} ->
        {values, acc} =
          Enum.map_reduce(1..(yields + 1), acc, fn point, acc ->
            draw(acc, {step, :schedule, point}, positions)
          end)

        {acc, Map.put(schedule, step, values)}
      end)
    end
  end

  # --- The pick

  defp slot(lane, slot, acc) do
    key = {lane, slot}
    pick_key = {key, :pick}
    offered = Enum.filter(acc.specs, &offered?(&1, acc.state))
    acc = %{acc | eligible: Enum.reduce(offered, acc.eligible, &MapSet.put(&2, &1.id))}

    case Map.fetch(acc.journal.entries, pick_key) do
      {:ok, {:empty} = entry} ->
        put_entry(acc, pick_key, entry)

      {:ok, {:pick, id, module} = entry} ->
        acc = put_entry(acc, pick_key, entry)

        case Enum.find(offered, &(&1.id == id and &1.command == module)) do
          nil -> withdraw(acc, key, module)
          spec -> step(spec, key, acc)
        end

      _none ->
        fresh_pick(offered, key, pick_key, acc)
    end
  end

  # A withdrawn slot keeps its field and assign entries, copied from the
  # journal it was rebuilt from, so a later edit that offers its command
  # again brings the command back with the values it had.
  defp withdraw(acc, key, module) do
    kept =
      Map.filter(acc.journal.entries, fn {entry_key, _entry} ->
        is_tuple(entry_key) and elem(entry_key, 0) == key
      end)

    %{
      acc
      | entries: Map.merge(acc.entries, kept),
        withdrawn: [%{key: key, command: module} | acc.withdrawn]
    }
  end

  defp fresh_pick([], _key, _pick_key, acc), do: acc

  defp fresh_pick(offered, key, pick_key, acc) do
    spec = weighted(offered, Journal.key_seed(acc.journal.seed, pick_key))
    acc |> put_entry(pick_key, {:pick, spec.id, spec.command}) |> then(&step(spec, key, &1))
  end

  defp offered?(%StepSpec{when: nil}, _state), do: true
  defp offered?(%StepSpec{when: predicate}, state), do: predicate.(state) not in [false, nil]

  defp weighted(specs, seed) do
    total = specs |> Enum.map(& &1.weight) |> Enum.sum()
    {point, _state} = :rand.uniform_s(total, :rand.seed_s(:exsss, seed))

    Enum.reduce_while(specs, point, fn spec, left ->
      if left <= spec.weight, do: {:halt, spec}, else: {:cont, left - spec.weight}
    end)
  end

  # --- One step

  defp step(%StepSpec{} = spec, key, acc) do
    {command, acc} = draw_command(spec, key, acc)
    {assigns, acc} = draw_assigns(spec, command, key, acc)
    {path, acc} = draw_path(spec.command, command, key, acc)
    step = %Step{key: key, spec_id: spec.id, command: command, assigns: assigns, path: path}
    %{predict(command, key, acc) | steps: [step | acc.steps]}
  end

  defp predict(command, key, acc) do
    state =
      command
      |> acc.simulator.simulate(acc.state)
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> mark_externals(event, key, index, []) end)
      |> Enum.reduce(acc.state, &acc.projection.apply(&2, &1))

    %{acc | state: state}
  end

  # --- The command

  defp draw_command(%StepSpec{command: module} = spec, key, acc) do
    fields =
      acc.state
      |> module.generator(spec.command_opts)
      |> field_map!(module)
      |> apply_changes(spec.changes, acc.state, module)
      |> check_fields!(module)

    {drawn, acc} =
      fields
      |> draw_order(module)
      |> Enum.reduce({%{}, acc}, fn field, {drawn, acc} ->
        {value, acc} = draw_field(module, field, Map.fetch!(fields, field), drawn, key, acc)
        {Map.put(drawn, field, value), acc}
      end)

    {struct!(module, drawn), acc}
  end

  defp field_map!(%{} = fields, _module) when not is_struct(fields), do: fields

  defp field_map!(other, module) do
    raise ArgumentError,
          "#{inspect(module)}.generator/2 must return a plain map from field name to " <>
            "generator, such as %{amount: integer(1..100)}, got: #{inspect(other)}"
  end

  defp apply_changes(fields, changes, state, module) do
    Enum.reduce(changes, fields, fn
      {:put, field, generator}, acc -> Map.put(acc, field, generator)
      {:update, fun}, acc -> acc |> fun.(state) |> field_map!(module)
    end)
  end

  defp check_fields!(fields, module) do
    struct_fields = module.__struct__() |> Map.delete(:__struct__)

    Enum.each(fields, fn {field, value} ->
      unless is_atom(field) and Map.has_key?(struct_fields, field) do
        raise ArgumentError,
              "#{inspect(module)}: the generator map names #{inspect(field)}, " <>
                "which is not a field of the struct"
      end

      unless match?(%From{}, value) or GeneratorCheck.accepted?(value) do
        GeneratorCheck.refuse!(value, "#{inspect(module)}, field #{inspect(field)}")
      end
    end)

    fields
  end

  # Fields with no from/2 first, sorted by name so a journal replays the
  # same way on every machine; then each from/2 field once the fields it
  # names are drawn, the lowest name first among those ready.
  defp draw_order(fields, module) do
    {dependent, plain} = Enum.split_with(fields, &match?({_, %From{}}, &1))

    sources =
      Map.new(dependent, fn {field, %From{fields: names}} -> {field, List.wrap(names)} end)

    for {field, names} <- sources, name <- names, not Map.has_key?(fields, name) do
      raise ArgumentError,
            "#{inspect(module)}, field #{inspect(field)}: from/2 names #{inspect(name)}, " <>
              "which the generator map does not draw"
    end

    plain = plain |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    order_dependent(plain, sources, module)
  end

  defp order_dependent(done, sources, _module) when map_size(sources) == 0, do: done

  defp order_dependent(done, sources, module) do
    ready =
      sources
      |> Enum.filter(fn {_field, names} -> Enum.all?(names, &(&1 in done)) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case ready do
      [field | _] ->
        order_dependent(done ++ [field], Map.delete(sources, field), module)

      [] ->
        raise ArgumentError,
              "#{inspect(module)}: the from/2 fields #{inspect(sources |> Map.keys() |> Enum.sort())} " <>
                "depend on each other in a cycle"
    end
  end

  defp draw_field(module, field, %From{fields: names, fun: fun}, drawn, key, acc) do
    generator = names |> inputs(drawn) |> fun.() |> from_result(module, field)
    draw(acc, {key, :command, field}, generator)
  end

  defp draw_field(_module, field, generator, _drawn, key, acc),
    do: draw(acc, {key, :command, field}, generator)

  defp inputs(name, drawn) when is_atom(name), do: Map.fetch!(drawn, name)
  defp inputs(names, drawn), do: Map.take(drawn, names)

  # What a from/2 function returned, as the engine receives it (see
  # `dependent/2`).
  defp from_result(%From{}, module, field) do
    raise ArgumentError,
          "#{inspect(module)}, field #{inspect(field)}: the from/2 function returned another " <>
            "from/2. Write a chain of dependencies as separate fields."
  end

  defp from_result(value, module, field) do
    unless GeneratorCheck.accepted?(value) do
      GeneratorCheck.refuse!(
        value,
        "#{inspect(module)}, field #{inspect(field)}, the value its from/2 function returned"
      )
    end

    dependent(value, %{site: :field, command: module, key: field, spec: nil})
  end

  # A PD description or a mint as it is; any other generator wrapped with
  # its site, so the engine knows it depends on another value of the step.
  defp dependent(%Gen{kind: kind} = description, _site) when kind != :delegated,
    do: description

  defp dependent(%Mint{} = marker, _site), do: marker
  defp dependent(generator, site), do: %Dependent{generator: generator, site: site}

  # --- Assigns

  defp draw_assigns(%StepSpec{assigns: assigns} = spec, command, key, acc) do
    {from_command, plain} = Enum.split_with(assigns, &match?({_, %FromCommand{}}, &1))

    plain = Enum.sort_by(plain, &elem(&1, 0))
    from_command = Enum.sort_by(from_command, &elem(&1, 0))

    {drawn, acc} =
      Enum.reduce(plain, {%{}, acc}, fn {name, generator}, {drawn, acc} ->
        {value, acc} = draw(acc, {key, :assigns, name}, generator)
        {Map.put(drawn, name, value), acc}
      end)

    Enum.reduce(from_command, {drawn, acc}, fn {name, %FromCommand{fun: fun}}, {drawn, acc} ->
      generator = fun.(command)

      unless GeneratorCheck.accepted?(generator) do
        GeneratorCheck.refuse!(
          generator,
          "the assign_from_command/3 function of #{inspect(name)}"
        )
      end

      site = %{site: :assign, command: spec.command, key: name, spec: spec.id}
      {value, acc} = draw(acc, {key, :assigns, name}, dependent(generator, site))
      {Map.put(drawn, name, value), acc}
    end)
  end

  # --- The path

  # The step's path, for a command module the model lists in expansions/0:
  # the pick drawn as a member of the path indexes, so that lowering it moves
  # the step toward its plain path at index 0, then the picked path's own
  # draws, names ascending. An unlisted module draws nothing and has no path.
  defp draw_path(module, command, key, acc) do
    case acc.expansions do
      %{^module => paths_fun} ->
        paths = paths!(paths_fun.(command, acc.state), command, module)
        indexes = Enum.to_list(0..(length(paths) - 1))
        {index, acc} = draw(acc, {key, :path}, Gen.member_of(indexes))
        {commands, acc} = path_commands(Enum.at(paths, index), module, key, acc)
        {{index, commands}, acc}

      _unlisted ->
        {nil, acc}
    end
  end

  defp paths!([first | _] = paths, command, _module) when first == [command], do: paths

  defp paths!(other, command, module) do
    raise ArgumentError,
          "the paths function of #{inspect(module)} must return a list of paths whose " <>
            "first is the command alone, #{inspect([command])}, got: #{inspect(other)}"
  end

  defp path_commands({generators, builder}, module, key, acc)
       when is_map(generators) and not is_struct(generators) and is_function(builder, 1) do
    {values, acc} =
      generators
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, acc}, fn {name, generator}, {values, acc} ->
        path_generator!(name, generator, module)
        {value, acc} = draw(acc, {key, :path, name}, generator)
        {Map.put(values, name, value), acc}
      end)

    {commands!(builder.(values), module), acc}
  end

  defp path_commands(commands, module, _key, acc), do: {commands!(commands, module), acc}

  defp path_generator!(name, generator, module) do
    unless is_atom(name) do
      raise ArgumentError,
            "a path of #{inspect(module)} draws under #{inspect(name)}, which is not an atom"
    end

    unless GeneratorCheck.accepted?(generator) do
      GeneratorCheck.refuse!(generator, "a path of #{inspect(module)}, draw #{inspect(name)}")
    end
  end

  defp commands!([_ | _] = commands, module) do
    if Enum.all?(commands, &is_struct/1), do: commands, else: path_error!(commands, module)
  end

  defp commands!(other, module), do: path_error!(other, module)

  defp path_error!(other, module) do
    raise ArgumentError,
          "a path of #{inspect(module)} is a non-empty list of command structs, or " <>
            "{generators, builder} whose builder returns one, got: #{inspect(other)}"
  end

  # --- Drawing one value

  # A marker drawn under `{step, kind, name}` is stamped with the step and
  # the path `[kind, name]`, where it sits in the step; a stamped marker,
  # read back from the predicted state, keeps the stamp it has.
  defp draw(acc, {step, kind, name}, %Mint{position: nil} = marker),
    do: {Mint.reify(marker, step, [kind, name]), acc}

  defp draw(acc, _key, %Mint{} = marker), do: {marker, acc}

  defp draw(acc, key, %Dependent{generator: generator, site: site} = dependent) do
    cond do
      fits_dependent?(acc.engine, generator) ->
        engine_draw(acc, key, dependent)

      acc.mode == :raise ->
        raise DependentStreamDataError, site: site, generator: generator

      true ->
        kept = if site in acc.kept, do: acc.kept, else: [site | acc.kept]
        engine_draw(%{acc | kept: kept}, key, dependent)
    end
  end

  defp draw(acc, key, generator), do: engine_draw(acc, key, generator)

  defp engine_draw(acc, key, generator) do
    {value, entry} = acc.engine.draw(acc.journal, key, generator, acc.journal.seed)
    {value, %{put_entry(acc, key, entry) | drawn: [key | acc.drawn]}}
  end

  # An engine says it can fit a dependent value by exporting
  # `fits_dependent?/1` and answering true; without it, it cannot.
  defp fits_dependent?(engine, generator) do
    Code.ensure_loaded?(engine) and function_exported?(engine, :fits_dependent?, 1) and
      engine.fits_dependent?(generator) == true
  end

  defp put_entry(acc, key, entry), do: %{acc | entries: Map.put(acc.entries, key, entry)}

  # --- Values the system under test mints

  # Replaces each external() marker in a predicted event with a placeholder
  # naming the step, the event's index and the field's path.
  defp mark_externals(value, key, index, path) do
    cond do
      External.external?(value) ->
        %Placeholder{step: key, event_index: index, path: Enum.reverse(path)}

      is_struct(value) ->
        value
        |> Map.from_struct()
        |> Enum.reduce(value, fn {field, inner}, acc ->
          Map.put(acc, field, mark_externals(inner, key, index, [field | path]))
        end)

      is_map(value) ->
        Map.new(value, fn {k, inner} -> {k, mark_externals(inner, key, index, [k | path])} end)

      is_list(value) ->
        mark_list(value, 0, key, index, path)

      true ->
        value
    end
  end

  defp mark_list([head | tail], position, key, index, path),
    do: [
      mark_externals(head, key, index, [position | path])
      | mark_list(tail, position + 1, key, index, path)
    ]

  defp mark_list(tail, _position, _key, _index, _path), do: tail
end
