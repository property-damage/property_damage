defmodule PropertyDamage.Expansion do
  @moduledoc false
  # Each target of a run runs its own concrete sequence: per root, either the
  # root itself or the leaves of one of the expansions the model's
  # `expansions/0` lists for it. This module checks `expansions/0` when a
  # model is loaded and turns a generated root sequence into every target's
  # concrete sequence before any target is set up.
  #
  # A target chooses at each root by its `expansion:` option:
  #
  #   :random     draws an entry by weight. The draw is seeded from the run
  #               seed, the target's name and the root id (`seed_key/3`),
  #               hashed as `PropertyDamage.Mint.resolve/3` hashes, so it is the
  #               same in any process on any machine and does not depend on
  #               the order of `targets:`.
  #   :identity   runs every root as itself.
  #   :reference  copies the first target's choices, leaf for leaf.
  #
  # Each walk starts from the state the setup commands leave and folds, root
  # after root, either the root or the realized leaves into the target's own
  # simulated state, so an expansion function and a leaf's `overrides:` see
  # what this target ran before.
  #
  # A realized entry is pure in its inputs: the root, the state at the root,
  # the entry, and the seed key its leaves draw their values from. A caller
  # that already knows the entry passes it with `:carry` (see `expand/5`), and
  # the leaves are realized again without a draw.

  alias PropertyDamage.{
    Comparison,
    Generator,
    Model,
    Placeholder,
    PlaceholderRegistry,
    Sequence,
    Validation
  }

  alias PropertyDamage.Sequence.Position

  @typedoc """
  What a target ran at one root.

    * `root` - the root's index in the sequence
    * `root_id` - the root's index as generated, kept by shrink candidates
    * `module` - the root's command module
    * `entry` - the entry key (`"Root[i]"`), `nil` when no expansion applied
      (the root is not listed, the model has no `expansions/0`, or the target
      runs `:identity`), or `:forced` when no listed entry could be realized
    * `index` - the entry's index in the list the function returned, or nil
    * `commands` - the commands executed for the root, in order
    * `leaves?` - true when `commands` are leaves at leaf positions; false when
      the root ran as itself at its own position (the identity included)
    * `seed_key` - the term the leaves' values were generated from, or nil
    * `aliases` - `%{root placeholder id => leaf placeholder id}`
    * `offered` - for a root the target drew at, every entry the function
      returned there, as `{key, leaf modules}`
  """
  @type choice :: %{
          required(:root) => non_neg_integer(),
          required(:root_id) => non_neg_integer(),
          required(:module) => module(),
          required(:entry) => String.t() | nil | :forced,
          required(:index) => non_neg_integer() | nil,
          required(:commands) => [struct()],
          required(:leaves?) => boolean(),
          required(:seed_key) => term() | nil,
          required(:aliases) => %{Placeholder.id() => Placeholder.id()},
          optional(:offered) => [{String.t(), [module()]}]
        }

  @typedoc """
  Every target's concrete sequence for one run, keyed by target name: its
  choices in root order and the placeholder registry its commands resolve
  against. `warnings` lists the `when:` and `weight:` options found on leaves,
  which a run ignores.
  """
  @type t :: %{
          variants: %{String.t() => %{choices: [choice()], registry: PlaceholderRegistry.t()}},
          warnings: [String.t()]
        }

  # ==========================================================================
  # The model
  # ==========================================================================

  @doc false
  # The model's expansion functions keyed by root module, or nil when the model
  # does not define `expansions/0`.
  @spec functions(module()) :: %{module() => function()} | nil
  def functions(model) do
    if defines?(model), do: Map.new(model.expansions()), else: nil
  end

  @doc false
  # Whether `model` defines `expansions/0`.
  @spec defines?(module()) :: boolean()
  def defines?(model) do
    Code.ensure_loaded(model)
    function_exported?(model, :expansions, 0)
  end

  @doc false
  # The load-time rules for `expansions/0`, checked before any target is set
  # up: a list of `{Root, fun}` pairs, each `fun` of arity 2, each `Root` a
  # module of `commands/0` listed once and not a `:probe` command, and a
  # `@compare` that reaches the final boundary. The function bodies are not
  # called here: what they return is checked when a run realizes them.
  # Raises `ArgumentError`.
  @spec check_model!(module()) :: :ok
  def check_model!(model) do
    if defines?(model), do: check_pairs!(model, model.expansions())
    :ok
  end

  defp check_pairs!(model, pairs) when is_list(pairs) do
    # A command's spec comes from its `command_spec/1`, which a module not
    # loaded yet does not export: load every root first.
    Enum.each(model.commands(), &(&1 |> Model.entry_module() |> Code.ensure_loaded()))

    roots =
      model.commands() |> Model.normalize_commands() |> Map.new(fn {_w, m, spec} -> {m, spec} end)

    _seen =
      Enum.reduce(pairs, MapSet.new(), fn pair, seen ->
        root = check_pair!(pair, roots)

        if MapSet.member?(seen, root) do
          raise ArgumentError,
                "expansions/0 lists #{inspect(root)} twice: give each root module one function"
        end

        MapSet.put(seen, root)
      end)

    check_compares_at_end!(model)
  end

  defp check_pairs!(_model, other) do
    raise ArgumentError,
          "expansions/0 must return a list of `{RootModule, function}` pairs, got: " <>
            inspect(other, limit: 8)
  end

  defp check_pair!({root, fun}, roots) when is_atom(root) do
    if not is_function(fun, 2) do
      raise ArgumentError,
            "expansions/0: the function for #{inspect(root)} must take 2 arguments " <>
              "(the root command and the state), got: #{inspect(fun)}"
    end

    case Map.fetch(roots, root) do
      :error ->
        raise ArgumentError,
              "expansions/0 lists #{inspect(root)}, which is not in commands/0: only a root " <>
                "command expands (setup and teardown commands never do)"

      {:ok, %{execution: :probe}} ->
        raise ArgumentError,
              "expansions/0 lists #{inspect(root)}, an `execution: :probe` command: a probe " <>
                "root is read again while a comparison waits, and a sequence of leaves " <>
                "cannot be read again"

      {:ok, _spec} ->
        root
    end
  end

  defp check_pair!(other, _roots) do
    raise ArgumentError,
          "expansions/0 must return `{RootModule, function}` pairs, got: #{inspect(other)}"
  end

  # A rewrite is equivalent to its root once the root is done, so the run
  # must compare the targets once every root is done: at the final boundary.
  defp check_compares_at_end!(model) do
    if not Enum.any?(Comparison.observations(model), &reaches_end?(&1.schedule)) do
      raise ArgumentError,
            "#{inspect(model)} defines expansions/0 but no @compare function compares " <>
              "at the final boundary, where every expansion must agree with its root. " <>
              "Declare one with `@compare every: 1` or with a schedule naming the end, " <>
              "`@compare every: :end` (or `every: [Module, :end]`)."
    end
  end

  defp reaches_end?(%{end: true}), do: true
  defp reaches_end?(%{roots: :all}), do: true
  defp reaches_end?(_schedule), do: false

  @doc false
  # The run options a model with expansions cannot take: `branching:`.
  @spec check_options!(module(), keyword()) :: :ok
  def check_options!(model, opts) do
    if opts[:branching] && defines?(model) do
      raise ArgumentError,
            "`branching:` cannot be used with #{inspect(model)}, which defines " <>
              "expansions/0: a branching sequence runs on one target without expansions"
    end

    :ok
  end

  # ==========================================================================
  # A run
  # ==========================================================================

  @doc false
  # Every target's concrete sequence for the linear `sequence`, generated from
  # `run_seed`. Raises `ArgumentError` for a generation error (an entry of the
  # wrong shape, an `overrides:` that raises, a root placeholder no single leaf
  # produces), before any target is set up.
  #
  # Options:
  #
  #   :root_ids  the generation id of each root (default: its index)
  #   :carry     `%{name => %{root_id => choice}}`: the choices a target made
  #              before. A carried entry is realized again from its seed key
  #              without a draw; a root with no carried choice runs as itself.
  @spec expand(module(), Sequence.t(), [PropertyDamage.Target.t()], integer(), keyword()) :: t()
  def expand(model, %Sequence{} = sequence, targets, run_seed, opts \\ []) do
    carry = Keyword.get(opts, :carry)
    walk = walk_state(model, sequence, Keyword.get(opts, :root_ids), run_seed)

    {variants, warnings} =
      Enum.reduce(targets, {%{}, []}, fn target, {variants, warnings} ->
        {variant, more} =
          case target.expansion do
            :reference -> {Map.fetch!(variants, hd(targets).name), []}
            mode -> walk(walk, target.name, mode, carry && Map.get(carry, target.name, %{}))
          end

        {Map.put(variants, target.name, variant), warnings ++ more}
      end)

    %{variants: variants, warnings: Enum.uniq(warnings)}
  end

  @doc false
  # What one target ran for `sequence`, realized again without a draw from the
  # choices it made there (`choices`, one per root in order, as a report's
  # trace keeps them): its choices and the registry its commands resolve
  # against. The roots keep the root ids of `choices`. A model without
  # `expansions/0` runs the roots of `sequence`.
  @spec carried(module(), Sequence.t(), [choice()]) :: %{
          choices: [choice()],
          registry: PlaceholderRegistry.t()
        }
  def carried(model, %Sequence{} = sequence, choices) do
    if defines?(model) do
      walk = walk_state(model, sequence, Enum.map(choices, & &1.root_id), nil)
      {variant, _warnings} = walk(walk, nil, :random, Map.new(choices, &{&1.root_id, &1}))
      variant
    else
      %{variants: %{nil => variant}} = identity(sequence, [%{name: nil}])
      variant
    end
  end

  @doc false
  # The choices of every target of `expansion`, keyed by target name and root
  # id: the `:carry` option of `expand/5`. Accepts what `expand/5` returns or a
  # report trace's `%{name => [choice]}`.
  @spec carry(t() | %{String.t() => [choice()]}) :: %{
          String.t() => %{non_neg_integer() => choice()}
        }
  def carry(%{variants: variants}),
    do: carry(Map.new(variants, fn {name, %{choices: choices}} -> {name, choices} end))

  def carry(choices_by_name) do
    Map.new(choices_by_name, fn {name, choices} ->
      {name, Map.new(choices, &{&1.root_id, &1})}
    end)
  end

  @doc false
  # The choices a report's trace carries (`traced`, `%{name => [choice]}`) for
  # a path that re-executes the report's sequence on the targets named
  # `names`: nil for a model without `expansions/0`, whose roots run as
  # themselves. Raises `ArgumentError` naming `path` when the trace does not
  # carry what one of those targets ran: running it as itself, or drawing its
  # expansions again, would not re-execute the failure.
  @spec traced!(module(), %{String.t() => [choice()]} | nil, [String.t()], String.t()) ::
          %{String.t() => [choice()]} | nil
  def traced!(model, traced, names, path) do
    missing = names -- Map.keys(traced || %{})

    cond do
      not defines?(model) ->
        nil

      missing == [] ->
        traced

      true ->
        raise ArgumentError,
              "#{inspect(model)} defines expansions/0, and the report does not record what " <>
                "target(s) #{Enum.map_join(missing, ", ", &inspect/1)} ran at each root, so " <>
                "#{path} cannot re-execute the failure's expanded sequence on them yet; " <>
                "re-execute it on the report's own targets"
    end
  end

  @doc false
  # The root ids of a report trace's choices, in root order (nil for nil).
  @spec root_ids(%{String.t() => [choice()]} | nil) :: [non_neg_integer()] | nil
  def root_ids(nil), do: nil

  def root_ids(traced) when map_size(traced) > 0,
    do: traced |> Map.values() |> hd() |> Enum.map(& &1.root_id)

  def root_ids(_traced), do: nil

  defp walk_state(model, sequence, root_ids, run_seed) do
    roots = Sequence.to_list(sequence)
    indices = Enum.to_list(0..(length(roots) - 1)//1)

    %{
      model: model,
      functions: functions(model) || %{},
      preconditions: preconditions(model),
      registry: sequence.registry || PlaceholderRegistry.new(),
      start: start_state(model, sequence),
      roots: Enum.zip([roots, root_ids || indices, indices]),
      run_seed: run_seed
    }
  end

  # A model without expansions has nothing to fold: every walk runs the roots.
  defp start_state(model, sequence) do
    if defines?(model), do: Generator.setup_state(model, sequence), else: nil
  end

  # Per command module, the `when:` specs of its commands/0 entries.
  defp preconditions(model) do
    model.commands()
    |> Model.normalize_commands()
    |> Enum.group_by(fn {_weight, module, _spec} -> module end, fn {_w, _m, spec} -> spec end)
  end

  defp walk(walk, name, mode, carry) do
    {choices, {_state, registry, warnings}} =
      Enum.map_reduce(walk.roots, {walk.start, walk.registry, []}, fn {root, root_id, index},
                                                                      {state, registry, warnings} ->
        fun = Map.get(walk.functions, root.__struct__)
        base = %{root: index, root_id: root_id, root_command: root, state: state}

        carried = if carry, do: Map.get(carry, root_id, :none)

        {choice, state, minted, aliases, more} =
          choose(walk, name, mode, fun, base, carried)

        registry = registry |> register(minted) |> alias_all(aliases)
        {choice, {state, registry, warnings ++ more}}
      end)

    {%{choices: choices, registry: registry}, warnings}
  end

  defp register(registry, placeholders),
    do: Enum.reduce(placeholders, registry, &PlaceholderRegistry.register(&2, &1))

  defp alias_all(registry, aliases) do
    Enum.reduce(aliases, registry, fn {root, leaf}, acc ->
      PlaceholderRegistry.alias_to(acc, root, leaf)
    end)
  end

  # Returns `{choice, state, minted, aliases, warnings}`: the choice, the
  # state after the root, the leaves' placeholders, and the
  # `{root_placeholder, leaf_placeholder}` pairs to alias.
  defp choose(walk, _name, mode, fun, base, _carried) when mode == :identity or fun == nil,
    do: as_itself(walk, base, nil, nil)

  defp choose(walk, _name, :random, _fun, base, :none), do: as_itself(walk, base, nil, nil)

  defp choose(walk, _name, :random, _fun, base, %{} = carried) do
    case carried do
      %{entry: entry} when entry in [nil, :forced] ->
        as_itself(walk, base, entry, nil)

      %{leaves?: false} ->
        as_itself(walk, base, carried.entry, carried.index)

      %{index: index, seed_key: seed_key} ->
        sequence = carried_sequence(walk, base, index)

        case realize(walk, base, {sequence, 1, index}, seed_key) do
          {:ok, realized} -> realized
          :withdrawn -> as_itself(walk, base, :forced, nil)
        end
    end
  end

  defp choose(walk, name, :random, fun, base, _carried), do: draw(walk, name, fun, base)

  # The carried entry, from the list the function returns for the root and
  # state of this walk. A function that no longer returns that entry (for a
  # root whose arguments a shrink simplified, say) cannot run it: the walk
  # fails as a generation error, which makes a shrink candidate invalid.
  defp carried_sequence(walk, base, index) do
    entries = entries!(walk, base, Map.fetch!(walk.functions, base.root_command.__struct__))

    case Enum.at(entries, index) do
      {sequence, _weight, ^index} ->
        sequence

      nil ->
        raise ArgumentError,
              "expansions/0: #{key(base, index)} (root #{base.root}) is no longer returned " <>
                "for #{inspect(base.root_command)}: the function returned " <>
                "#{length(entries)} expansion(s)"
    end
  end

  defp as_itself(walk, base, entry, index) do
    state =
      Generator.simulate_root(
        walk.model,
        base.root_command,
        Position.prefix(base.root),
        base.state,
        walk.registry
      )

    choice = %{
      root: base.root,
      root_id: base.root_id,
      module: base.root_command.__struct__,
      entry: entry,
      index: index,
      commands: [base.root_command],
      leaves?: false,
      seed_key: nil,
      aliases: %{}
    }

    {choice, state, [], [], []}
  end

  # ==========================================================================
  # The draw
  # ==========================================================================

  defp draw(walk, name, fun, base) do
    entries = entries!(walk, base, fun)
    seed_key = seed_key(walk.run_seed, name, base.root_id)
    rand = :rand.seed_s(:exsss, seed_integer(seed_key))
    {choice, state, minted, aliases, warnings} = draw_among(walk, base, entries, seed_key, rand)
    {Map.put(choice, :offered, offered(base, entries)), state, minted, aliases, warnings}
  end

  # The entries the function returned at the root, as `{key, leaf modules}`.
  defp offered(base, entries) do
    for {sequence, _weight, index} <- entries do
      {key(base, index), Enum.map(sequence, &spec_module/1)}
    end
  end

  defp spec_module(%module{}), do: module
  defp spec_module({module, _opts}), do: module
  defp spec_module(module), do: module

  defp draw_among(walk, base, [], _seed_key, _rand), do: as_itself(walk, base, :forced, nil)

  defp draw_among(walk, base, entries, seed_key, rand) do
    total = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {pick, rand} = :rand.uniform_s(total, rand)
    entry = pick_by_weight(entries, pick)

    case realize(walk, base, entry, seed_key) do
      {:ok, realized} -> realized
      :withdrawn -> draw_among(walk, base, List.delete(entries, entry), seed_key, rand)
    end
  end

  defp pick_by_weight([{_sequence, weight, _index} = entry | rest], n) do
    if n <= weight, do: entry, else: pick_by_weight(rest, n - weight)
  end

  @doc false
  # The term every draw at one root of one target derives from: the run seed,
  # the target name and the root id. A leaf's values come from this term and
  # its leaf index.
  @spec seed_key(integer(), String.t(), non_neg_integer()) :: term()
  def seed_key(run_seed, name, root_id), do: {run_seed, name, root_id}

  # A digest of `term`, hashed as `PropertyDamage.Mint.resolve/3` hashes, as a
  # non-negative integer seed.
  defp seed_integer(term) do
    <<seed::unsigned-64, _rest::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(term, minor_version: 2))

    seed
  end

  # The entries `fun` returns for the root, as `{sequence, weight, index}`.
  defp entries!(walk, base, fun) do
    case fun.(base.root_command, base.state) do
      entries when is_list(entries) ->
        entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} -> entry!(walk, base, entry, index) end)

      other ->
        raise ArgumentError,
              "expansions/0: the function for #{inspect(base.root_command.__struct__)} " <>
                "(root #{base.root}) must return a list of expansions, got: " <>
                inspect(other, limit: 8)
    end
  end

  defp entry!(_walk, _base, sequence, index) when is_list(sequence), do: {sequence, 1, index}

  defp entry!(_walk, base, {sequence, opts}, index) when is_list(sequence) and is_list(opts) do
    case Keyword.fetch(opts, :weight) do
      {:ok, weight} when is_integer(weight) and weight > 0 and length(opts) == 1 ->
        {sequence, weight, index}

      _other ->
        raise ArgumentError,
              "expansions/0: #{key(base, index)} (root #{base.root}) has options " <>
                "#{inspect(opts)}; an expansion takes only `weight:`, a positive integer"
    end
  end

  defp entry!(_walk, base, other, index) do
    raise ArgumentError,
          "expansions/0: #{key(base, index)} (root #{base.root}) must be a list of commands " <>
            "or `{list, weight: n}`, got: #{inspect(other, limit: 8)}"
  end

  # ==========================================================================
  # Realization
  # ==========================================================================

  # Realizes one entry at a root. Returns `{:ok, {choice, state, minted,
  # aliases, warnings}}`, or `:withdrawn` when a leaf fails its precondition.
  defp realize(walk, base, {[root], _weight, index}, _seed_key)
       when is_struct(root) and root == base.root_command do
    {:ok, as_itself(walk, base, key(base, index), index)}
  end

  defp realize(walk, base, {sequence, _weight, index}, seed_key) do
    key = key(base, index)

    sequence
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, base.state, [], [], []}, fn {spec, leaf},
                                                           {:ok, state, done, minted, warnings} ->
      case realize_leaf(walk, base, key, spec, leaf, state, done, seed_key) do
        :withdrawn ->
          {:halt, :withdrawn}

        {command, events, state, new_minted, more} ->
          {:cont,
           {:ok, state, done ++ [%{command: command, events: events}], minted ++ new_minted,
            warnings ++ more}}
      end
    end)
    |> case do
      :withdrawn ->
        :withdrawn

      {:ok, state, done, minted, warnings} ->
        aliases = aliases!(walk, base, key, done, minted)

        choice = %{
          root: base.root,
          root_id: base.root_id,
          module: base.root_command.__struct__,
          entry: key,
          index: index,
          commands: Enum.map(done, & &1.command),
          leaves?: true,
          seed_key: seed_key,
          aliases: Map.new(aliases, fn {root, leaf} -> {root.id, leaf.id} end)
        }

        {:ok, {choice, state, minted, aliases, warnings}}
    end
  end

  defp realize_leaf(_walk, base, key, spec, leaf, _state, _done, _seed_key)
       when is_struct(spec) do
    raise ArgumentError,
          "expansions/0: #{key} (root #{base.root}) holds a command struct at position " <>
            "#{leaf}: only the root the function received may appear in a sequence, " <>
            "alone, as the identity"
  end

  defp realize_leaf(walk, base, key, spec, leaf, state, done, seed_key) do
    {_weight, module, resolved} = normalize_leaf!(base, key, spec, leaf)
    warnings = ignored_options(base, key, spec, leaf)

    if precondition_holds?(walk, module, state) do
      overrides = overrides!(base, key, module, leaf, resolved, state, done)
      command = generate_leaf!(base, key, module, leaf, overrides, state, seed_key)
      position = Position.leaf(base.root_id, leaf)

      {command, events, state, minted} =
        Generator.simulate_step(walk.model, command, position, state)

      {command, events, state, minted, warnings}
    else
      :withdrawn
    end
  end

  defp normalize_leaf!(base, key, spec, leaf) do
    Model.normalize_sequence_entry(spec)
  rescue
    e in [ArgumentError, CaseClauseError] ->
      reraise ArgumentError,
              [
                message:
                  "expansions/0: #{key} (root #{base.root}), leaf #{leaf}: " <>
                    leaf_message(e, spec)
              ],
              __STACKTRACE__
  end

  defp leaf_message(%ArgumentError{message: message}, _spec), do: message

  defp leaf_message(_error, spec),
    do: "expected `Module` or `{Module, opts}`, got: #{inspect(spec, limit: 8)}"

  # `when:` and `weight:` on a leaf are ignored: every leaf of an expansion runs.
  defp ignored_options(base, key, {module, opts}, leaf) when is_list(opts) do
    for option <- [:when, :weight], Keyword.has_key?(opts, option) do
      "expansions/0: #{key} (#{inspect(base.root_command.__struct__)}) leaf #{leaf} " <>
        "#{inspect(module)} sets #{option}: ignored in a sequence"
    end
  end

  defp ignored_options(_base, _key, _spec, _leaf), do: []

  # A leaf's precondition is its module's `commands/0` `when:`: it holds when
  # the module has no entry there, or when any entry's `when:` holds.
  defp precondition_holds?(walk, module, state) do
    case Map.get(walk.preconditions, module) do
      nil -> true
      specs -> Enum.any?(specs, &Generator.precondition_holds?(&1, state))
    end
  end

  defp overrides!(base, key, module, leaf, resolved, state, done) do
    case Map.get(resolved, :overrides) do
      nil -> %{}
      map when is_map(map) -> map
      fun when is_function(fun, 1) -> fun.(state)
      fun when is_function(fun, 2) -> fun.(state, done)
    end
  rescue
    e ->
      reraise ArgumentError,
              [
                message:
                  "expansions/0: #{key} (root #{base.root}), leaf #{leaf} #{inspect(module)}: " <>
                    "its `overrides:` raised: " <> Exception.message(e)
              ],
              __STACKTRACE__
  end

  defp generate_leaf!(base, key, module, leaf, overrides, state, seed_key) do
    check_leaf_module!(base, key, module, leaf)

    module
    |> Generator.command_generator(overrides, state)
    |> Generator.generate_value(seed_integer({seed_key, leaf}))
  rescue
    e ->
      reraise ArgumentError, [message: leaf_error(base, key, module, leaf, e)], __STACKTRACE__
  end

  defp leaf_error(base, key, module, leaf, e) do
    message = Exception.message(e)

    if String.starts_with?(message, "expansions/0:") do
      message
    else
      "expansions/0: #{key} (root #{base.root}), leaf #{leaf} #{inspect(module)}: " <>
        "cannot generate the leaf: " <> message
    end
  end

  # A leaf module is validated the first time this process realizes it: it
  # must exist and have the callbacks of a command (`generator/1`, or `new!/2`
  # for a nemesis). A pass is kept in the process dictionary for the rest of
  # the process, so later realizations skip the check; a failure is never
  # kept, so every realization of a broken module fails the same way. Each
  # validation emits `[:property_damage, :expansion, :leaf_validated]`. The
  # keys of a leaf's `overrides:` depend on the entry, not the module, and are
  # checked at every realization when the leaf's generator is built.
  defp check_leaf_module!(base, key, module, leaf) do
    if Process.get({__MODULE__, :valid_leaf, module}) do
      :ok
    else
      validate_leaf_module!(base, key, module, leaf)
    end
  end

  defp command_callbacks(module) do
    Validation.validate_command_callbacks!(module)
  rescue
    e in ArgumentError -> {:error, String.trim(e.message)}
  end

  defp validate_leaf_module!(base, key, module, leaf) do
    result =
      if Code.ensure_loaded?(module),
        do: command_callbacks(module),
        else: {:error, "command module #{inspect(module)} does not exist"}

    :telemetry.execute([:property_damage, :expansion, :leaf_validated], %{}, %{
      module: module,
      root: base.root_command.__struct__,
      entry: key,
      result: if(result == :ok, do: :ok, else: :error)
    })

    case result do
      :ok ->
        Process.put({__MODULE__, :valid_leaf, module}, true)
        :ok

      {:error, message} ->
        raise ArgumentError,
              "expansions/0: #{key} (#{inspect(base.root_command.__struct__)}, root " <>
                "#{base.root}), leaf #{leaf} #{inspect(module)}: " <> message
    end
  end

  # ==========================================================================
  # Aliases
  # ==========================================================================

  # Each placeholder the root's simulation minted resolves, in a target that
  # ran a rewrite, from the one leaf whose simulated events hold the same
  # event module at the same field path.
  defp aliases!(walk, base, key, done, minted) do
    walk.registry
    |> PlaceholderRegistry.ids_at_position(Position.prefix(base.root))
    |> Enum.map(&PlaceholderRegistry.get(walk.registry, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn root -> {root, alias_leaf!(base, key, done, minted, root)} end)
  end

  defp alias_leaf!(base, key, done, minted, root) do
    candidates =
      minted
      |> Enum.filter(&(&1.event_module == root.event_module and &1.path == root.path))
      |> Enum.uniq_by(& &1.position)

    case candidates do
      [leaf] ->
        leaf

      _zero_or_several ->
        produced =
          Enum.map_join(candidates, ", ", fn %{position: %{offset: leaf}} ->
            "leaf #{leaf} (#{inspect(Enum.at(done, leaf).command.__struct__)})"
          end)

        leaves = Enum.map_join(done, ", ", &inspect(&1.command.__struct__))

        raise ArgumentError,
              "expansions/0: #{key} (root #{base.root}) must produce the root's external() " <>
                "field #{inspect(root.path)} of #{inspect(root.event_module)} from exactly one " <>
                "leaf, so later commands can use it; " <>
                if(candidates == [],
                  do: "no leaf of [#{leaves}] produces it",
                  else: "several do: #{produced}"
                )
    end
  end

  # ==========================================================================
  # Sampling
  # ==========================================================================

  @doc false
  # Generates a root sequence for each seed, realizes every target's
  # expansions on it, and summarizes what the sample realized:
  #
  #   realized    %{key => {leaf modules, count}}, counts summed over targets
  #   offered     %{key => leaf modules}: every entry a function returned
  #   forced      the root modules forced to identity at every root a target
  #               chose at
  #   leaves      the leaf modules realized
  #   warnings    the `when:` and `weight:` options found on leaves
  #
  # Raises `ArgumentError` for a generation error, as a run does.
  @spec sample(module(), [PropertyDamage.Target.t()], [integer()], keyword()) :: map()
  def sample(model, targets, seeds, opts \\ []) do
    generator = Generator.generate_sequence(model, Keyword.take(opts, [:max_commands]))

    choices_and_warnings =
      for seed <- seeds do
        sequence = Generator.generate_value(generator, seed)
        expansion = expand(model, sequence, targets, seed)
        choices = for {_name, %{choices: choices}} <- expansion.variants, c <- choices, do: c
        {choices, expansion.warnings}
      end

    choices = Enum.flat_map(choices_and_warnings, &elem(&1, 0))
    chosen = Enum.filter(choices, &Map.has_key?(&1, :offered))

    realized =
      for %{entry: key, commands: commands} = choice <- chosen, is_binary(key), reduce: %{} do
        acc ->
          modules =
            if choice.leaves?, do: Enum.map(commands, & &1.__struct__), else: [choice.module]

          Map.update(acc, key, {modules, 1}, fn {modules, n} -> {modules, n + 1} end)
      end

    %{
      realized: realized,
      offered: chosen |> Enum.flat_map(& &1.offered) |> Map.new(),
      forced:
        chosen
        |> Enum.group_by(& &1.module)
        |> Enum.filter(fn {_module, group} -> Enum.all?(group, &(&1.entry == :forced)) end)
        |> Enum.map(&elem(&1, 0)),
      leaves:
        for(
          %{leaves?: true, commands: commands} <- chosen,
          c <- commands,
          into: MapSet.new(),
          do: c.__struct__
        ),
      warnings: choices_and_warnings |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
    }
  end

  # ==========================================================================
  # Reading a run
  # ==========================================================================

  # The entry key of entry `index` at the root `base` names.
  defp key(base, index), do: "#{short(base.root_command.__struct__)}[#{index}]"

  @doc false
  # The last segment of a module name.
  @spec short(module()) :: String.t()
  def short(module), do: module |> Module.split() |> List.last()

  @doc false
  # The expansion of a run of a model without expansions, or of a branching
  # run: every target runs the roots of `sequence`.
  @spec identity(Sequence.t(), [PropertyDamage.Target.t()]) :: t()
  def identity(%Sequence{} = sequence, targets) do
    choices =
      sequence
      |> Sequence.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {root, index} ->
        %{
          root: index,
          root_id: index,
          module: root.__struct__,
          entry: nil,
          index: nil,
          commands: [root],
          leaves?: false,
          seed_key: nil,
          aliases: %{}
        }
      end)

    registry = sequence.registry || PlaceholderRegistry.new()
    variant = %{choices: choices, registry: registry}
    %{variants: Map.new(targets, &{&1.name, variant}), warnings: []}
  end

  @doc false
  # What each target executes per root, in target order: per root a list of
  # `{command, position}`, where position is nil for a root that runs as
  # itself at its own position, and the target's registry.
  @spec schedule([PropertyDamage.Target.t()], t()) :: [
          %{roots: [[{struct(), Position.t() | nil}]], registry: PlaceholderRegistry.t()}
        ]
  def schedule(targets, %{variants: variants}) do
    for target <- targets do
      %{choices: choices, registry: registry} = Map.fetch!(variants, target.name)
      %{roots: steps(choices), registry: registry}
    end
  end

  @doc false
  # What a target executes per root for its `choices`: per root a list of
  # `{command, position}`, position nil for a root that runs as itself.
  @spec steps([choice()]) :: [[{struct(), Position.t() | nil}]]
  def steps(choices) when is_list(choices), do: Enum.map(choices, &root_steps/1)

  defp root_steps(%{leaves?: false, commands: commands}), do: Enum.map(commands, &{&1, nil})

  defp root_steps(%{leaves?: true, commands: commands, root_id: root_id}) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {command, leaf} -> {command, Position.leaf(root_id, leaf)} end)
  end

  @doc false
  # Per target name, per listed root module: how many times each entry was
  # realized, and `:forced` for a root that ran as itself because no entry
  # could be. Roots no expansion applied to are not counted.
  @spec counts(t() | nil) :: %{
          String.t() => %{module() => %{(String.t() | :forced) => pos_integer()}}
        }
  def counts(nil), do: %{}

  def counts(%{variants: variants}) do
    Map.new(variants, fn {name, %{choices: choices}} ->
      {name,
       Enum.reduce(choices, %{}, fn
         %{entry: nil}, acc ->
           acc

         %{entry: entry, module: module}, acc ->
           Map.update(acc, module, %{entry => 1}, &Map.update(&1, entry, 1, fn n -> n + 1 end))
       end)}
    end)
  end

  @doc false
  # Adds the counts of `right` into `left`.
  @spec merge_counts(map(), map()) :: map()
  def merge_counts(left, right) do
    Map.merge(left, right, fn _name, a, b ->
      Map.merge(a, b, fn _module, x, y -> Map.merge(x, y, fn _key, m, n -> m + n end) end)
    end)
  end

  @doc false
  # The report's `expansions` field: per target name, one element per root the
  # run executed, up to the failing root (`failed_at` nil: every root).
  @spec report(t() | nil, non_neg_integer() | nil) :: %{String.t() => [map()]}
  def report(nil, _failed_at), do: %{}

  def report(%{variants: variants}, failed_at) do
    Map.new(variants, fn {name, %{choices: choices}} ->
      executed = if failed_at, do: Enum.take(choices, failed_at + 1), else: choices

      {name,
       Enum.map(executed, fn choice ->
         %{
           root: choice.root,
           entry: choice.entry,
           leaves: Enum.map(choice.commands, & &1.__struct__)
         }
       end)}
    end)
  end
end
