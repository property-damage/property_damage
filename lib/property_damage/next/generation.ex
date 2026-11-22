defmodule PropertyDamage.Next.Generation do
  @moduledoc false
  # Builds a plan from a model and a journal, slot by slot, carrying the
  # predicted state.
  #
  # At each slot it keeps the specs whose `when:` holds on the predicted
  # state and picks one: the stored pick if the journal has one and that
  # spec is still offered, a weighted draw from the key's seed if the
  # journal has none. A stored pick no longer offered withdraws the slot:
  # no step, and generation goes on. The picked spec's command fields and
  # assigns are drawn through the engine, each under its own key; then the
  # simulator predicts the command's events and the command-sequence
  # projection folds them into the state the next slot reads.
  #
  # Keys: the step is `{lane, slot}`, with lane 0 for a one-lane plan and
  # slots counted from 1. A draw is `{step, :pick}`,
  # `{step, :command, field}` or `{step, :assigns, key}`.

  alias PropertyDamage.External
  alias PropertyDamage.Mint
  alias PropertyDamage.Next.Engine.Dependent

  alias PropertyDamage.Next.{
    From,
    Gen,
    GeneratorCheck,
    Journal,
    Placeholder,
    Plan,
    Step,
    StepSpec
  }

  alias PropertyDamage.Next.StepSpec.FromCommand

  @lane 0

  @doc "Builds the plan of `specs` from `journal`."
  @spec build(module(), [StepSpec.t()], Journal.t(), keyword()) :: Plan.t()
  def build(model, specs, %Journal{} = journal, opts) do
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
      withdrawn: []
    }

    acc = Enum.reduce(1..Keyword.fetch!(opts, :max_steps)//1, acc, &slot/2)

    %Plan{
      steps: Enum.reverse(acc.steps),
      journal: %{journal | entries: acc.entries},
      withdrawn: Enum.reverse(acc.withdrawn)
    }
  end

  # --- The pick

  defp slot(slot, acc) do
    key = {@lane, slot}
    pick_key = {key, :pick}
    offered = Enum.filter(acc.specs, &offered?(&1, acc.state))

    case Map.fetch(acc.journal.entries, pick_key) do
      {:ok, {:pick, id, module} = entry} ->
        acc = put_entry(acc, pick_key, entry)

        case Enum.find(offered, &(&1.id == id and &1.command == module)) do
          nil -> %{acc | withdrawn: [%{key: key, command: module} | acc.withdrawn]}
          spec -> step(spec, key, acc)
        end

      _none ->
        fresh_pick(offered, key, pick_key, acc)
    end
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
    step = %Step{key: key, spec_id: spec.id, command: command, assigns: assigns}
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

  defp draw_field(_module, _field, %Mint{} = marker, _drawn, _key, acc), do: {marker, acc}

  defp draw_field(module, field, %From{fields: names, fun: fun}, drawn, key, acc) do
    generator = names |> inputs(drawn) |> fun.() |> dependent(module, field)
    draw(acc, {key, :command, field}, generator)
  end

  defp draw_field(_module, field, generator, _drawn, key, acc),
    do: draw(acc, {key, :command, field}, generator)

  defp inputs(name, drawn) when is_atom(name), do: Map.fetch!(drawn, name)
  defp inputs(names, drawn), do: Map.take(drawn, names)

  # What a from/2 function returned, as the engine receives it: a PD
  # description or a mint as it is, any other generator wrapped so the
  # engine knows it depends on another field.
  defp dependent(%From{}, module, field) do
    raise ArgumentError,
          "#{inspect(module)}, field #{inspect(field)}: the from/2 function returned another " <>
            "from/2. Write a chain of dependencies as separate fields."
  end

  defp dependent(%Gen{kind: kind} = description, _module, _field) when kind != :delegated,
    do: description

  defp dependent(%Mint{} = marker, _module, _field), do: marker

  defp dependent(generator, module, field) do
    if GeneratorCheck.generator?(generator) do
      %Dependent{generator: generator, command: module, field: field}
    else
      GeneratorCheck.refuse!(
        generator,
        "#{inspect(module)}, field #{inspect(field)}, the value its from/2 function returned"
      )
    end
  end

  # --- Assigns

  defp draw_assigns(%StepSpec{assigns: assigns}, command, key, acc) do
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

      {value, acc} = draw(acc, {key, :assigns, name}, generator)
      {Map.put(drawn, name, value), acc}
    end)
  end

  # --- Drawing one value

  defp draw(acc, _key, %Mint{} = marker), do: {marker, acc}

  defp draw(acc, key, generator) do
    {value, entry} = acc.engine.draw(acc.journal, key, generator, acc.journal.seed)
    {value, put_entry(acc, key, entry)}
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
