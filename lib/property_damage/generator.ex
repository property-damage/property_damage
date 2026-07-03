defmodule PropertyDamage.Generator do
  @moduledoc """
  Generates command sequences for stateful property-based testing.

  This module produces `PropertyDamage.Sequence` structs that can be either:
  - **Linear sequences**: Commands executed sequentially
  - **Branching sequences**: Commands with parallel execution branches

  ## Linear Sequence Generation

      Generator.generate_sequence(MyModel, max_commands: 20)
      # => StreamData producing %Sequence{prefix: [...], branches: nil}

  ## Branching Sequence Generation

      Generator.generate_sequence(MyModel,
        max_commands: 20,
        branching: [
          branch_probability: 0.3,  # 30% chance to create branch point
          max_branches: 3,          # Up to 3 parallel branches
          max_branch_length: 5      # Each branch max 5 commands
        ]
      )
      # => StreamData producing %Sequence{prefix: [...], branches: [[...], [...]], suffix: [...]}

  ## Ref Dependency Rules

  When generating branching sequences, the generator enforces ref isolation:
  - Refs created in `prefix` can be used in any branch
  - Refs created in one branch CANNOT be used in another branch
  - Refs created in branches CAN be used in `suffix`

  ## Auto-Lifting

  Raw values passed as overrides are automatically wrapped in `StreamData.constant/1`:

      merge_overrides(base, %{currency: "USD"})
      merge_overrides(base, %{currency: StreamData.member_of(["USD", "EUR"])})
  """

  alias PropertyDamage.External
  alias PropertyDamage.Mint
  alias PropertyDamage.Nemesis
  alias PropertyDamage.{Placeholder, PlaceholderRegistry, Sequence}

  @type command :: struct()
  @type state :: map()
  @type weighted_command :: {pos_integer(), module()}

  # Default options
  @default_max_commands 50
  @default_branch_probability 0.2
  @default_max_branches 3
  @default_max_branch_length 5
  @default_min_prefix_length 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate a command sequence for a given model.

  ## Parameters

  - `model` - Model module defining commands and state projection
  - `opts` - Options:
    - `:max_commands` - Maximum total commands per sequence (default: 50)
    - `:branching` - Keyword list for branching configuration (see below)

  Note: the returned generator is pure; reproducibility comes from consuming
  it with `generate_value/3` and an explicit seed.

  ## Branching Options

  Pass `branching: [...]` to generate branching sequences:

  - `:branch_probability` - Probability of creating a branch point (default: 0.2)
  - `:max_branches` - Maximum number of parallel branches (default: 3)
  - `:max_branch_length` - Maximum commands per branch (default: 5)
  - `:min_prefix_length` - Minimum commands before branching (default: 3)

  If `:branching` is not provided, generates linear sequences.

  ## Returns

  A StreamData generator that produces `PropertyDamage.Sequence` structs.

  ## Examples

      # Linear sequence
      Generator.generate_sequence(MyModel, max_commands: 20)

      # Branching sequence with 30% branch probability
      Generator.generate_sequence(MyModel,
        max_commands: 30,
        branching: [branch_probability: 0.3, max_branches: 2]
      )
  """
  @spec generate_sequence(module(), keyword()) :: StreamData.t(PropertyDamage.Sequence.t())
  def generate_sequence(model, opts \\ []) do
    max_commands = Keyword.get(opts, :max_commands, @default_max_commands)
    branching_opts = Keyword.get(opts, :branching, nil)
    markers = Keyword.get(opts, :external_markers, [])
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()
    projection = model.command_sequence_projection()

    StreamData.bind(StreamData.constant(nil), fn _ ->
      if branching_opts do
        do_generate_branching_sequence(
          commands,
          projection,
          model,
          max_commands,
          branching_opts,
          markers
        )
      else
        do_generate_linear_sequence(commands, projection, model, max_commands, markers)
      end
    end)
  end

  # Size passed to StreamData when realizing a value. Constant (rather than
  # growing per run) so that a sequence is a pure function of the seed alone,
  # which is what makes "reproduce with seed N" exact.
  @generation_size 30

  @doc """
  Deterministically realizes a single value from a StreamData generator.

  Consuming a generator via `Enum`/`Enumerable` seeds from the wall clock
  (see `StreamData` docs), which silently breaks seed reproducibility.
  All framework code MUST realize generated values through this function.
  """
  @spec generate_value(StreamData.t(val), integer(), keyword()) :: val when val: var
  def generate_value(generator, seed, opts \\ []) when is_integer(seed) do
    size = Keyword.get(opts, :size, @generation_size)

    generator
    |> StreamData.seeded(seed)
    |> StreamData.resize(size)
    |> Enum.at(0)
  end

  @doc """
  Derives the effective seed for a given run number from the base seed.

  Run 0 uses the base seed unchanged, so re-running a failure's reported
  seed with `max_runs: 1` regenerates exactly the failing sequence.
  Later runs get independent, well-mixed sub-seeds.
  """
  @spec run_seed(integer(), non_neg_integer()) :: integer()
  def run_seed(seed, 0) when is_integer(seed), do: seed

  def run_seed(seed, run_number) when is_integer(seed) and is_integer(run_number) do
    :erlang.phash2({seed, run_number}, 4_294_967_296)
  end

  @doc """
  Merge overrides into base generators, auto-lifting raw values.

  Raw values are automatically wrapped in `StreamData.constant/1`.
  StreamData generators are passed through unchanged.

  ## Parameters

  - `base` - Map of field names to StreamData generators
  - `overrides` - Map of field names to values or generators to override

  ## Returns

  A map suitable for passing to `StreamData.fixed_map/1`.

  ## Examples

      iex> base = %{amount: StreamData.positive_integer(), currency: StreamData.constant("USD")}
      iex> result = PropertyDamage.Generator.merge_overrides(base, %{currency: "EUR"})
      iex> is_map(result)
      true
  """
  @spec merge_overrides(map(), map()) :: map()
  def merge_overrides(base, overrides) do
    Map.merge(base, lift_values(overrides))
  end

  @doc """
  Check if a value is a StreamData generator.

  ## Examples

      iex> PropertyDamage.Generator.stream_data?(StreamData.integer())
      true

      iex> PropertyDamage.Generator.stream_data?(42)
      false
  """
  @spec stream_data?(any()) :: boolean()
  def stream_data?(%StreamData{}), do: true
  def stream_data?(_), do: false

  # ============================================================================
  # Linear Sequence Generation
  # ============================================================================

  defp do_generate_linear_sequence(commands, projection, model, max_commands, markers) do
    initial_state = projection.init()

    generate_linear_recursive(
      commands,
      projection,
      model,
      initial_state,
      max_commands,
      [],
      [],
      markers,
      &{:prefix, &1}
    )
    |> StreamData.map(fn {cmds, placeholders} ->
      attach_registry(Sequence.linear(cmds), placeholders)
    end)
  end

  # Recursion threads two accumulators: `acc` (commands, reversed) and `acc_ph`
  # (placeholders minted so far). `pos_fun` maps a command's local 0-based index
  # to its structured position (DR-021), so the same recursion serves the linear
  # path ({:prefix, i}), the branch-continuation suffix, and post-branch suffix.
  defp generate_linear_recursive(_commands, _projection, _model, _state, 0, acc, acc_ph, _m, _pf) do
    StreamData.constant({Enum.reverse(acc), acc_ph})
  end

  defp generate_linear_recursive(
         commands,
         projection,
         model,
         state,
         remaining,
         acc,
         acc_ph,
         markers,
         pos_fun
       ) do
    valid_commands = filter_valid_commands(commands, state)

    case valid_commands do
      [] ->
        StreamData.constant({Enum.reverse(acc), acc_ph})

      _ ->
        StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module, opts} ->
          generator = get_command_generator(cmd_module, opts, state)

          StreamData.bind(generator, fn command ->
            position = pos_fun.(length(acc))
            command = reify_command_mints(command, position)
            events = simulate_command(model, state, command)
            {events, minted} = instantiate_placeholders(events, position, markers)
            new_state = update_state(state, command, events, projection)
            new_acc = [command | acc]
            new_acc_ph = acc_ph ++ minted

            if should_terminate?(model, new_state, command, events) do
              StreamData.constant({Enum.reverse(new_acc), new_acc_ph})
            else
              generate_linear_recursive(
                commands,
                projection,
                model,
                new_state,
                remaining - 1,
                new_acc,
                new_acc_ph,
                markers,
                pos_fun
              )
            end
          end)
        end)
    end
  end

  # ============================================================================
  # Branching Sequence Generation
  # ============================================================================

  defp do_generate_branching_sequence(commands, projection, model, max_commands, opts, markers) do
    branch_probability = Keyword.get(opts, :branch_probability, @default_branch_probability)
    max_branches = Keyword.get(opts, :max_branches, @default_max_branches)
    max_branch_length = Keyword.get(opts, :max_branch_length, @default_max_branch_length)
    min_prefix_length = Keyword.get(opts, :min_prefix_length, @default_min_prefix_length)

    initial_state = projection.init()

    # First, generate the prefix (before any branching)
    generate_prefix(
      commands,
      projection,
      model,
      initial_state,
      min_prefix_length,
      max_commands,
      [],
      [],
      markers
    )
    |> StreamData.bind(fn
      {prefix, _state_after_prefix, _remaining, prefix_ph, true} ->
        # DR-013: the model terminated the sequence during the prefix, so it
        # stays linear with nothing appended (no branches, no suffix).
        StreamData.constant(attach_registry(Sequence.linear(prefix), prefix_ph))

      {prefix, state_after_prefix, remaining, prefix_ph, false} ->
        prefix_len = length(prefix)

        # Decide whether to branch
        StreamData.bind(StreamData.float(min: 0.0, max: 1.0), fn roll ->
          if roll < branch_probability and remaining > max_branch_length do
            # Generate branches
            generate_with_branches(
              commands,
              projection,
              model,
              state_after_prefix,
              prefix,
              prefix_ph,
              remaining,
              max_branches,
              max_branch_length,
              markers
            )
          else
            # Continue as linear sequence: the whole thing stays linear, so suffix
            # positions continue the prefix's {:prefix, _} numbering.
            generate_linear_recursive(
              commands,
              projection,
              model,
              state_after_prefix,
              remaining,
              [],
              [],
              markers,
              &{:prefix, prefix_len + &1}
            )
            |> StreamData.map(fn {suffix_cmds, suffix_ph} ->
              attach_registry(Sequence.linear(prefix ++ suffix_cmds), prefix_ph ++ suffix_ph)
            end)
          end
        end)
    end)
  end

  defp generate_prefix(
         commands,
         projection,
         model,
         state,
         min_length,
         max_total,
         acc,
         acc_ph,
         markers
       ) do
    if length(acc) >= min_length do
      # Met minimum, return what we have
      remaining = max_total - length(acc)
      StreamData.constant({Enum.reverse(acc), state, remaining, acc_ph, false})
    else
      valid_commands = filter_valid_commands(commands, state)

      case valid_commands do
        [] ->
          # No valid commands, end early
          remaining = max_total - length(acc)
          StreamData.constant({Enum.reverse(acc), state, remaining, acc_ph, false})

        _ ->
          StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module, opts} ->
            generator = get_command_generator(cmd_module, opts, state)

            StreamData.bind(generator, fn command ->
              position = {:prefix, length(acc)}
              command = reify_command_mints(command, position)
              events = simulate_command(model, state, command)
              {events, minted} = instantiate_placeholders(events, position, markers)
              new_state = update_state(state, command, events, projection)
              new_acc = [command | acc]
              new_acc_ph = acc_ph ++ minted

              if should_terminate?(model, new_state, command, events) do
                # DR-013: terminate? stops the WHOLE sequence, not just the
                # prefix. Signal it so no branches or suffix get appended.
                remaining = max_total - length(new_acc)

                StreamData.constant(
                  {Enum.reverse(new_acc), new_state, remaining, new_acc_ph, true}
                )
              else
                generate_prefix(
                  commands,
                  projection,
                  model,
                  new_state,
                  min_length,
                  max_total,
                  new_acc,
                  new_acc_ph,
                  markers
                )
              end
            end)
          end)
      end
    end
  end

  defp generate_with_branches(
         commands,
         projection,
         model,
         state_at_branch,
         prefix,
         prefix_ph,
         remaining,
         max_branches,
         max_branch_length,
         markers
       ) do
    # Decide number of branches (at least 2)
    num_branches = min(max_branches, max(2, div(remaining, max_branch_length)))

    # Calculate max length per branch
    per_branch_max = min(max_branch_length, div(remaining, num_branches))

    # Generate each branch independently from the same state snapshot. Each
    # branch mints with a {:branch, b, i} position (b is the branch's index in
    # the full generator list); empty branches are dropped below and surviving
    # branch indices are remapped to match the executor's branch_id ordering.
    branch_generators =
      for b <- 0..(num_branches - 1) do
        generate_branch(
          commands,
          projection,
          model,
          state_at_branch,
          per_branch_max,
          [],
          [],
          markers,
          fn i -> {:branch, b, i} end
        )
      end

    # combine_branches yields a list of {branch_commands, branch_placeholders}.
    StreamData.bind(combine_branches(branch_generators), fn branch_results ->
      branches = Enum.map(branch_results, fn {branch, _ph} -> branch end)

      # Compute merged state after all branches
      merged_state = merge_branch_states(state_at_branch, branches, projection, model)

      # Remaining commands for suffix
      branch_command_count = Enum.sum(Enum.map(branches, &length/1))
      suffix_remaining = max(0, remaining - branch_command_count)

      # Generate suffix
      generate_linear_recursive(
        commands,
        projection,
        model,
        merged_state,
        suffix_remaining,
        [],
        [],
        markers,
        &{:suffix, &1}
      )
      |> StreamData.map(fn {suffix_cmds, suffix_ph} ->
        assemble_branching(prefix, prefix_ph, branch_results, suffix_cmds, suffix_ph)
      end)
    end)
  end

  # Drop empty branches and build the final sequence. Surviving branches are
  # renumbered to a contiguous 0..k range (matching the executor's branch_id),
  # and their placeholders' {:branch, _, i} positions remapped accordingly. If
  # fewer than 2 branches survive the sequence collapses to linear, so branch
  # and suffix placeholders are remapped onto the continuing {:prefix, _} space.
  defp assemble_branching(prefix, prefix_ph, branch_results, suffix_cmds, suffix_ph) do
    surviving = Enum.reject(branch_results, fn {branch, _ph} -> Enum.empty?(branch) end)

    if length(surviving) >= 2 do
      {branches, branch_ph} =
        surviving
        |> Enum.with_index()
        |> Enum.map_reduce([], fn {{branch, ph}, new_idx}, acc ->
          {branch, acc ++ rebranch(ph, new_idx)}
        end)

      attach_registry(
        Sequence.branching(prefix, branches, suffix_cmds),
        prefix_ph ++ branch_ph ++ suffix_ph
      )
    else
      base = length(prefix)

      {flattened, branch_ph, suffix_base} =
        Enum.reduce(surviving, {[], [], base}, fn {branch, ph}, {cmds, acc, offset} ->
          {cmds ++ branch, acc ++ to_prefix(ph, offset), offset + length(branch)}
        end)

      remapped_suffix_ph =
        Enum.map(suffix_ph, fn
          %Placeholder{position: {:suffix, i}} = p -> %{p | position: {:prefix, suffix_base + i}}
          p -> p
        end)

      attach_registry(
        Sequence.linear(prefix ++ flattened ++ suffix_cmds),
        prefix_ph ++ branch_ph ++ remapped_suffix_ph
      )
    end
  end

  defp rebranch(placeholders, new_idx) do
    Enum.map(placeholders, fn
      %Placeholder{position: {:branch, _old, i}} = p -> %{p | position: {:branch, new_idx, i}}
      p -> p
    end)
  end

  defp to_prefix(placeholders, offset) do
    Enum.map(placeholders, fn
      %Placeholder{position: {:branch, _old, i}} = p -> %{p | position: {:prefix, offset + i}}
      p -> p
    end)
  end

  defp generate_branch(_commands, _projection, _model, _state, 0, acc, acc_ph, _markers, _pos_fun) do
    StreamData.constant({Enum.reverse(acc), acc_ph})
  end

  defp generate_branch(
         commands,
         projection,
         model,
         state,
         remaining,
         acc,
         acc_ph,
         markers,
         pos_fun
       ) do
    valid_commands = filter_valid_commands(commands, state)

    case valid_commands do
      [] ->
        StreamData.constant({Enum.reverse(acc), acc_ph})

      _ ->
        # 30% chance to end branch early (creates varied branch lengths)
        StreamData.bind(StreamData.float(min: 0.0, max: 1.0), fn roll ->
          if roll < 0.3 and acc != [] do
            StreamData.constant({Enum.reverse(acc), acc_ph})
          else
            StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module, opts} ->
              generator = get_command_generator(cmd_module, opts, state)

              StreamData.bind(generator, fn command ->
                position = pos_fun.(length(acc))
                command = reify_command_mints(command, position)
                events = simulate_command(model, state, command)

                {events, minted} =
                  instantiate_placeholders(events, position, markers)

                new_state = update_state(state, command, events, projection)
                new_acc = [command | acc]
                new_acc_ph = acc_ph ++ minted

                if should_terminate?(model, new_state, command, events) do
                  StreamData.constant({Enum.reverse(new_acc), new_acc_ph})
                else
                  generate_branch(
                    commands,
                    projection,
                    model,
                    new_state,
                    remaining - 1,
                    new_acc,
                    new_acc_ph,
                    markers,
                    pos_fun
                  )
                end
              end)
            end)
          end
        end)
    end
  end

  defp combine_branches([]), do: StreamData.constant([])

  defp combine_branches([gen | rest]) do
    StreamData.bind(gen, fn branch ->
      StreamData.bind(combine_branches(rest), fn other_branches ->
        StreamData.constant([branch | other_branches])
      end)
    end)
  end

  defp merge_branch_states(base_state, branches, projection, model) do
    # Apply all branch commands to get merged state
    # Note: This is a simplification - real parallel execution would need
    # linearization checking. For generation, we just need a plausible state.
    all_branch_commands = List.flatten(branches)

    Enum.reduce(all_branch_commands, base_state, fn command, state ->
      # Simulate and apply
      events = simulate_command(model, state, command)
      update_state(state, command, events, projection)
    end)
  end

  # ============================================================================
  # Shared Helpers
  # ============================================================================

  defp filter_valid_commands(commands, state) do
    Enum.filter(commands, fn {_weight, cmd_module, spec} ->
      when_satisfied?(spec, state) and nemesis_precondition_satisfied?(cmd_module, state)
    end)
  end

  defp when_satisfied?(spec, state) do
    # spec is now a map with :when key
    case Map.get(spec, :when) do
      nil -> true
      pred when is_function(pred, 1) -> pred.(state)
    end
  end

  # A nemesis module's `precondition/1` is a generation-time filter, the nemesis
  # analogue of a command's `when:` (DR-031). Non-nemesis commands are unaffected.
  defp nemesis_precondition_satisfied?(cmd_module, state) do
    if Nemesis.nemesis_module?(cmd_module) do
      cmd_module.precondition(state)
    else
      true
    end
  end

  defp weighted_member_of(weighted_commands) do
    total_weight = Enum.reduce(weighted_commands, 0, fn {w, _, _}, acc -> acc + w end)

    StreamData.bind(StreamData.integer(1..total_weight), fn n ->
      select_by_weight(weighted_commands, n)
      |> StreamData.constant()
    end)
  end

  defp select_by_weight([{weight, cmd, opts} | rest], n) do
    if n <= weight do
      {weight, cmd, opts}
    else
      select_by_weight(rest, n - weight)
    end
  end

  defp get_command_generator(cmd_module, spec, state) do
    # spec is now a map with :with key
    overrides =
      case Map.get(spec, :with) do
        nil -> %{}
        fun when is_function(fun, 1) -> fun.(state)
        map when is_map(map) -> map
      end

    if Nemesis.nemesis_module?(cmd_module) do
      # DR-031: nemesis modules generate via `new!/2` (which already returns a
      # `StreamData.t(struct())`), not `generator/1` — they do not `use Command`.
      nemesis_generator(cmd_module, state, overrides)
    else
      validate_override_keys!(cmd_module, overrides)

      cmd_module.generator(overrides)
      |> StreamData.map(&struct!(cmd_module, &1))
    end
  end

  defp nemesis_generator(cmd_module, state, overrides) do
    # `function_exported?/3` is false for a not-yet-loaded module, so ensure the
    # module is loaded before reflecting on the optional `new!/2` callback.
    if Code.ensure_loaded?(cmd_module) and function_exported?(cmd_module, :new!, 2) do
      cmd_module.new!(state, overrides)
    else
      raise ArgumentError,
            "Nemesis #{inspect(cmd_module)} is listed in commands/0 but does not " <>
              "implement new!/2, so the generator cannot produce instances of it. " <>
              "Implement new!/2 (returning a StreamData generator of the nemesis " <>
              "struct), or only inject it via a pre-baked command sequence."
    end
  end

  # A `with:` override only takes effect for fields the command defines (the
  # generated map is built into the command struct, which rejects unknown keys).
  # An override targeting any other key is a silent no-op; surface it with a clear
  # error naming the command and offending field(s) rather than the opaque
  # KeyError that `struct!/2` would otherwise raise deep inside generation.
  defp validate_override_keys!(cmd_module, overrides) when map_size(overrides) > 0 do
    if Code.ensure_loaded?(cmd_module) and function_exported?(cmd_module, :__struct__, 0) do
      fields = cmd_module.__struct__() |> Map.from_struct() |> Map.keys()
      unknown = Map.keys(overrides) -- fields

      if unknown != [] do
        raise ArgumentError,
              "Invalid `with:` override for command #{inspect(cmd_module)}: " <>
                "field(s) #{inspect(unknown)} are not defined by the command " <>
                "(its fields are #{inspect(fields)}). An override for an undefined " <>
                "field has no effect; check for a typo or a renamed field."
      end
    end

    :ok
  end

  defp validate_override_keys!(_cmd_module, _overrides), do: :ok

  defp simulate_command(model, state, command) do
    # See PropertyDamage.Linearization: ensure the module is loaded before
    # function_exported?/3, which is false for a not-yet-loaded module.
    if Code.ensure_loaded?(model) and function_exported?(model, :simulator, 0) do
      model.simulator().simulate(command, state)
    else
      []
    end
  end

  defp update_state(state, command, events, projection) do
    state
    |> projection.apply(command)
    |> apply_events(events, projection)
  end

  defp apply_events(state, events, projection) do
    Enum.reduce(events, state, fn event, acc ->
      projection.apply(acc, event)
    end)
  end

  defp should_terminate?(model, state, command, events) do
    if Code.ensure_loaded?(model) and function_exported?(model, :terminate?, 3) do
      model.terminate?(state, command, events)
    else
      false
    end
  end

  defp lift_values(map) do
    Map.new(map, fn {k, v} -> {k, lift(v)} end)
  end

  defp lift(%StreamData{} = gen), do: gen
  defp lift(value), do: StreamData.constant(value)

  # ============================================================================
  # Placeholder instantiation (DR-021)
  # ============================================================================

  # Replace external() markers in simulated events with %Placeholder{} structs,
  # so projection state (and any consumer command that reads it) carries a
  # resolvable placeholder rather than a raw %External{} sentinel. Returns the
  # substituted events plus the list of minted placeholders for this command.
  defp instantiate_placeholders(events, position, markers) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {event, event_index}, minted ->
      mint_event_placeholders(event, event_index, position, markers, minted)
    end)
  end

  defp instantiate_placeholders(events, _position, _markers), do: {events, []}

  # Reify any mint_per_run markers in a generated command with their generation
  # coordinates (DR-034/DR-036): the command's structured `position` and the
  # field path. Baking coordinates in here (rather than keying on the flat
  # executor index) keeps sibling branches distinct and makes the minted value
  # stable under shrinking, since the marker travels inside the command struct.
  defp reify_command_mints(command, position) when is_struct(command) do
    reify_mints(command, position, [])
  end

  defp reify_command_mints(command, _position), do: command

  defp reify_mints(%Mint{} = marker, position, path), do: Mint.reify(marker, position, path)
  defp reify_mints(%Placeholder{} = p, _position, _path), do: p

  defp reify_mints(%{__struct__: mod} = struct, position, path) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {k, reify_mints(v, position, path ++ [k])} end)
    |> then(&struct(mod, &1))
  end

  defp reify_mints(map, position, path) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, reify_mints(v, position, path ++ [k])} end)
  end

  defp reify_mints(list, position, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> reify_mints(v, position, path ++ [i]) end)
  end

  defp reify_mints(tuple, position, path) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> reify_mints(v, position, path ++ [i]) end)
    |> List.to_tuple()
  end

  defp reify_mints(other, _position, _path), do: other

  defp mint_event_placeholders(event, event_index, position, markers, minted)
       when is_struct(event) do
    paths = External.external_paths(event.__struct__, markers)

    Enum.reduce(paths, {event, minted}, fn path, {ev, ms} ->
      ph = Placeholder.new_at(ev.__struct__, path, position, event_index)
      {External.put_at_path(ev, path, ph), ms ++ [ph]}
    end)
  end

  defp mint_event_placeholders(event, _event_index, _position, _markers, minted) do
    {event, minted}
  end

  defp attach_registry(sequence, []), do: sequence

  defp attach_registry(sequence, placeholders) do
    Sequence.with_registry(sequence, build_registry(placeholders))
  end

  defp build_registry(placeholders) do
    Enum.reduce(placeholders, PlaceholderRegistry.new(), &PlaceholderRegistry.register(&2, &1))
  end

  # ============================================================================
  # Consumer-routing affordance (DR-021)
  # ============================================================================

  @doc """
  List the external placeholders available in projection `state`.

  During generation, `external()` markers in simulated events become
  `%PropertyDamage.Placeholder{}` structs embedded in projection state. This
  surfaces them so a model's `with:` function can route one into a command that
  consumes a server-generated value.

  ## Options

  - `:event_module` - keep only placeholders produced by this event module
  - `:path` - keep only placeholders at this field path (e.g. `[:id]`)

  ## Example

      # In the model's command list:
      {ViewOrder, with: fn state ->
        %{order_id: PropertyDamage.Generator.external_from(state, path: [:id])}
      end}
  """
  @spec available_externals(map(), keyword()) :: [struct()]
  def available_externals(state, opts \\ []) do
    state
    |> PlaceholderRegistry.collect_placeholders()
    |> filter_by(:event_module, Keyword.get(opts, :event_module), &(&1.event_module == &2))
    |> filter_by(:path, Keyword.get(opts, :path), &(&1.path == &2))
  end

  @doc """
  A seeded generator that picks one external placeholder from `state`.

  Returns `StreamData.constant(nil)` when no matching external is available, so
  a `with:` function can guard on `nil`. Accepts the same options as
  `available_externals/2`.
  """
  @spec external_from(map(), keyword()) :: StreamData.t(struct() | nil)
  def external_from(state, opts \\ []) do
    case available_externals(state, opts) do
      [] -> StreamData.constant(nil)
      placeholders -> StreamData.member_of(placeholders)
    end
  end

  defp filter_by(list, _key, nil, _pred), do: list
  defp filter_by(list, _key, value, pred), do: Enum.filter(list, &pred.(&1, value))
end
