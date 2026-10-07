defmodule PropertyDamage.ReplayArtifact do
  @moduledoc false
  # A replay artifact records one failing run so it can be executed again
  # without generating anything: the setup commands with their arguments, the
  # roots, and per target the commands it ran at each root, leaves included.
  # A failing run writes it after shrinking (`PropertyDamage.run/1`,
  # `replay_dir:`) and `only: [replay: path]` executes it.
  #
  # The file is Elixir source holding one literal term after a header comment,
  # so a reader can follow it and an editor highlights it. It is read back as
  # data: the source is parsed with `Code.string_to_quoted/2` and a walker
  # accepts literals only. Nothing in the file is ever evaluated.
  #
  # The term:
  #
  #   %{
  #     format: 1,
  #     model: module,
  #     seed: the seed the run generated from,
  #     run: 1,
  #     targets: [%{name: name, expansion: mode}],      the reference first
  #     failure: %{kind:, name:, variant_index:, root_index:},
  #     prefix: [setup command],
  #     roots: [%{root_id: id, command: root command}],
  #     choices: %{name => [%{root_id:, entry:, commands:, aliases:}]}
  #   }
  #
  # The failure is recorded as data (its kind, its name, the failing target's
  # index and the root), never as the exception or mismatch it carried. The
  # teardown commands are not recorded: a replay draws them against the state
  # the roots leave, as every run does.
  #
  # This module is the one place that builds, writes, reads and re-executes an
  # artifact term: every path that re-executes a failure from a report's
  # `replay` term goes through it.

  alias PropertyDamage.{
    Expansion,
    Failure,
    FailureReport,
    Generator,
    PlaceholderRegistry,
    RunTrace,
    Sequence
  }

  alias PropertyDamage.Sequence.Position

  @format 1
  @header "# PropertyDamage replay artifact, format #{@format}"
  @header_prefix "# PropertyDamage replay artifact, format "
  @keys [:choices, :failure, :format, :model, :prefix, :roots, :run, :seed, :targets]
  @choice_keys [:root_id, :entry, :commands, :aliases]

  @type t :: %{
          format: pos_integer(),
          model: module(),
          seed: integer(),
          run: pos_integer(),
          targets: [%{name: String.t(), expansion: atom()}],
          failure: map(),
          prefix: [struct()],
          roots: [%{root_id: non_neg_integer(), command: struct()}],
          choices: %{String.t() => [map()]}
        }

  @typedoc """
  Where a value no artifact can hold sits: the target, the root's position in
  the recorded roots, the leaf's position in the commands the target ran
  there, and the path from the command's fields to the value (a list index as
  an integer, a map key as the key). A setup command is named by `root:
  :setup` and its position as `leaf`; a root command by `leaf: nil`.
  """
  @type refusal :: %{
          target: String.t() | nil,
          root: non_neg_integer() | :setup,
          leaf: non_neg_integer() | nil,
          field: [term()]
        }

  # ==========================================================================
  # Building the term
  # ==========================================================================

  @doc false
  # The artifact term of the run `report` describes, or nil when the report
  # records no target's choices (a latency report) or a branching sequence,
  # which an artifact cannot hold.
  @spec build(FailureReport.t()) :: t() | nil
  def build(
        %FailureReport{
          trace: %RunTrace{expansion: %{} = traced, plan: %Sequence{} = plan},
          targets: [_ | _]
        } = report
      )
      when map_size(traced) > 0 do
    targets = targets(report)

    if Sequence.linear?(plan) and Enum.all?(targets, &Map.has_key?(traced, &1.name)) do
      reference = hd(targets).name
      roots = Sequence.to_list(plan)
      ids = Enum.map(Map.fetch!(traced, reference), & &1.root_id)

      %{
        format: @format,
        model: report.model,
        seed: report.seed,
        run: 1,
        targets: targets,
        failure: %{
          kind: report.kind,
          name: Failure.name(report.failure_reason),
          variant_index: report.variant && report.variant.index,
          root_index: report.failed_at_index
        },
        prefix: report.setup_commands,
        roots: Enum.zip_with(ids, roots, &%{root_id: &1, command: &2}),
        choices:
          Map.new(targets, fn %{name: name} ->
            {name, Enum.map(Map.fetch!(traced, name), &Map.take(&1, @choice_keys))}
          end)
      }
    end
  end

  def build(%FailureReport{}), do: nil

  defp targets(%FailureReport{targets: entries}) do
    Enum.map(entries, fn {adapter, entry} ->
      %{
        name: Keyword.get(entry, :name) || PropertyDamage.Target.default_name(adapter),
        expansion: Keyword.get(entry, :expansion, :random)
      }
    end)
  end

  @doc false
  # `:ok`, or `{:refused, refusal}` naming the first value in `term` no file
  # can hold (a function, a pid, a reference, a port, an improper list or a
  # bitstring that is not a binary): in the targets' commands (target order,
  # then root order, then leaf order), then in the roots, then in the setup
  # commands.
  @spec check(t()) :: :ok | {:refused, refusal()}
  def check(term) do
    found =
      Enum.find_value(term.targets, &target_refusal(term, &1.name)) ||
        term.roots
        |> Enum.with_index()
        |> Enum.find_value(fn {%{command: command}, root} ->
          refusal(nil, root, nil, command)
        end) ||
        term.prefix
        |> Enum.with_index()
        |> Enum.find_value(fn {command, leaf} -> refusal(nil, :setup, leaf, command) end)

    if found, do: {:refused, found}, else: :ok
  end

  defp target_refusal(term, name) do
    term.choices
    |> Map.fetch!(name)
    |> Enum.with_index()
    |> Enum.find_value(fn {choice, root} ->
      choice.commands
      |> Enum.with_index()
      |> Enum.find_value(fn {command, leaf} -> refusal(name, root, leaf, command) end)
    end)
  end

  defp refusal(target, root, leaf, command) do
    case unprintable(fields(command), []) do
      nil -> nil
      path -> %{target: target, root: root, leaf: leaf, field: path}
    end
  end

  defp fields(%_{} = struct), do: Map.from_struct(struct)
  defp fields(other), do: other

  # The path to the first value no literal can hold, or nil.
  defp unprintable(value, path)
       when is_function(value) or is_pid(value) or is_reference(value) or is_port(value),
       do: Enum.reverse(path)

  defp unprintable(value, path) when is_bitstring(value) and not is_binary(value),
    do: Enum.reverse(path)

  defp unprintable(%_{} = struct, path), do: unprintable(Map.from_struct(struct), path)

  defp unprintable(map, path) when is_map(map) do
    map
    |> Enum.sort()
    |> Enum.find_value(fn {key, value} -> unprintable(value, [key | path]) end)
  end

  defp unprintable(list, path) when is_list(list) do
    if proper_list?(list) do
      list
      |> Enum.with_index()
      |> Enum.find_value(fn {value, index} -> unprintable(value, [index | path]) end)
    else
      Enum.reverse(path)
    end
  end

  defp unprintable(tuple, path) when is_tuple(tuple), do: unprintable(Tuple.to_list(tuple), path)
  defp unprintable(_value, _path), do: nil

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_improper), do: false

  @doc false
  # A refusal as text for a report footer.
  @spec describe_refusal(refusal()) :: String.t()
  def describe_refusal(%{target: target, root: root, leaf: leaf, field: field}) do
    where =
      case {target, root, leaf} do
        {nil, :setup, leaf} -> "setup command #{leaf}"
        {nil, root, nil} -> "the command of root #{root}"
        {target, root, leaf} -> "target #{inspect(target)}, root #{root}, command #{leaf}"
      end

    "#{where}, field #{field_text(field)}"
  end

  # `[:payload, 0, :f]` as `payload[0].f`.
  defp field_text(field) do
    field
    |> Enum.map_join(fn
      key when is_integer(key) -> "[#{key}]"
      key when is_atom(key) -> ".#{key}"
      key -> "[#{inspect(key)}]"
    end)
    |> String.trim_leading(".")
  end

  # ==========================================================================
  # Writing
  # ==========================================================================

  @doc false
  # The artifact's file name: the model's last name segment and the seed.
  @spec file_name(t()) :: String.t()
  def file_name(%{model: model, seed: seed}),
    do: "#{model |> Module.split() |> List.last()}_seed#{seed}.replay.exs"

  @doc false
  # Writes `term` into `dir` (created when missing), replacing the file a
  # failure of the same seed wrote before. Returns `{:ok, path}` or
  # `{:error, reason}`.
  @spec write(t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(term, dir) do
    path = Path.join(dir, file_name(term))

    with {:mkdir, :ok} <- {:mkdir, File.mkdir_p(dir)},
         {:write, :ok} <- {:write, File.write(path, encode(term))} do
      {:ok, path}
    else
      {:mkdir, {:error, reason}} -> {:error, {:mkdir_failed, dir, reason}}
      {:write, {:error, reason}} -> {:error, {:write_failed, path, reason}}
    end
  end

  @doc false
  # The artifact's text: the header and the comment lines naming the model,
  # the seed, the run and the targets, then the term, with a comment naming
  # each root and what each target ran there. Map keys and struct fields are
  # printed in sorted order and nothing depends on the clock, so the same
  # term always prints the same bytes.
  @spec encode(t()) :: String.t()
  def encode(term) do
    reference = hd(term.targets).name
    roots = Enum.map(term.roots, & &1.command)

    header =
      [
        @header,
        "# model: #{inspect(term.model)}",
        "# seed: #{term.seed}",
        "# run: #{term.run} (the run this seed generates)"
      ] ++
        Enum.map(term.targets, fn %{name: name, expansion: mode} ->
          marker = if name == reference, do: " (reference)", else: ""
          "# target #{inspect(name)}#{marker}, expansion: #{inspect(mode)}"
        end)

    body =
      Enum.map(@keys, fn
        :choices -> "choices: " <> choices_source(term, roots)
        :roots -> "roots: " <> roots_source(term.roots)
        key -> "#{key}: " <> literal(Map.fetch!(term, key))
      end)

    source = "%{\n" <> Enum.join(body, ",\n") <> "\n}\n"
    Enum.join(header, "\n") <> "\n" <> format(source)
  end

  defp choices_source(term, roots) do
    entries =
      Enum.map(Enum.sort_by(term.choices, &elem(&1, 0)), fn {name, choices} ->
        items =
          choices
          |> Enum.with_index()
          |> Enum.map(fn {choice, index} ->
            "# root #{index}: #{entry_text(choice, Enum.at(roots, index))}\n" <>
              literal(Map.take(choice, @choice_keys))
          end)

        literal(name) <> " => [\n" <> Enum.join(items, ",\n") <> "\n]"
      end)

    "%{\n" <> Enum.join(entries, ",\n") <> "\n}"
  end

  defp roots_source(roots) do
    items =
      roots
      |> Enum.with_index()
      |> Enum.map(fn {%{command: command} = root, index} ->
        "# root #{index}: #{Expansion.short(command.__struct__)}\n" <> literal(root)
      end)

    "[\n" <> Enum.join(items, ",\n") <> "\n]"
  end

  @doc false
  # What a target ran at one root, as the artifact's comments name it.
  @spec entry_text(map(), struct() | nil) :: String.t()
  def entry_text(%{entry: entry, commands: commands}, root) do
    leaves = Enum.map_join(commands, ", ", &Expansion.short(&1.__struct__))
    name = if root, do: Expansion.short(root.__struct__), else: leaves

    case entry do
      nil -> "#{name} (not expanded)"
      :identity -> "#{name} (identity, by shrinking)"
      :forced -> "#{name} (identity, forced)"
      key -> "#{key} = [#{leaves}]"
    end
  end

  # The formatter keeps the comments and the literals as written; it only
  # lays the source out.
  defp format(source), do: IO.iodata_to_binary([Code.format_string!(source), "\n"])

  # A value as an Elixir literal the loader reads back equal.
  defp literal(value) when is_atom(value), do: inspect(value)
  defp literal(value) when is_number(value), do: inspect(value)

  defp literal(value) when is_binary(value),
    do: inspect(value, binaries: :as_strings, printable_limit: :infinity, limit: :infinity)

  defp literal(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &literal/1) <> "]"

  defp literal(value) when is_tuple(value),
    do: "{" <> Enum.map_join(Tuple.to_list(value), ", ", &literal/1) <> "}"

  defp literal(%module{} = struct),
    do: "%" <> inspect(module) <> "{" <> pairs(Map.from_struct(struct)) <> "}"

  defp literal(map) when is_map(map), do: "%{" <> pairs(map) <> "}"

  defp pairs(map) do
    entries = Enum.sort(map)

    if Enum.all?(entries, fn {key, _value} -> is_atom(key) end) do
      Enum.map_join(entries, ", ", fn {key, value} ->
        Macro.inspect_atom(:key, key) <> " " <> literal(value)
      end)
    else
      Enum.map_join(entries, ", ", fn {key, value} -> literal(key) <> " => " <> literal(value) end)
    end
  end

  # ==========================================================================
  # Reading
  # ==========================================================================

  @doc false
  # The term the artifact at `path` holds, read as data.
  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, text} -> parse(text)
      {:error, reason} -> {:error, "cannot read the replay artifact #{path}: #{inspect(reason)}"}
    end
  end

  @doc false
  # The term an artifact's text holds. The text must start with the header
  # line and hold one literal term whose `format` agrees with the header;
  # anything that is not a literal is refused naming the node and its line.
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    with :ok <- check_header(text),
         {:ok, quoted} <- quote_text(text),
         {:ok, term} <- walk(quoted),
         :ok <- check_format(term) do
      check_shape(term)
    end
  end

  defp check_header(text) do
    case String.split(text, "\n", parts: 2) do
      [@header | _rest] ->
        :ok

      [@header_prefix <> format | _rest] ->
        {:error,
         "the replay artifact header names format #{String.trim(format)}; " <>
           "this version reads format #{@format}"}

      _ ->
        {:error, "the replay artifact has no header: its first line must be #{inspect(@header)}"}
    end
  end

  defp quote_text(text) do
    opts = [literal_encoder: &{:ok, {:__block__, &2, [&1]}}, emit_warnings: false]

    case Code.string_to_quoted(text, opts) do
      {:ok, {:__block__, _meta, [_first, second | _rest]}} ->
        {:error,
         "the replay artifact holds a second term, #{source(second)}, at line #{line(second)}: " <>
           "an artifact holds one term"}

      {:ok, quoted} ->
        {:ok, quoted}

      {:error, {meta, message, token}} ->
        {:error,
         "the replay artifact is not valid Elixir at line #{Keyword.get(meta, :line, "?")}: " <>
           "#{inspect(message)} #{inspect(token)}"}
    end
  end

  defp check_format(%{format: @format}), do: :ok

  defp check_format(%{format: format}),
    do:
      {:error,
       "the replay artifact header names format #{@format} and its term names " <>
         "format: #{inspect(format)}"}

  defp check_format(_term),
    do: {:error, "the replay artifact's term is not a map with a format: key"}

  defp check_shape(term) do
    keys = term |> Map.keys() |> Enum.sort()

    cond do
      keys != @keys ->
        {:error,
         "the replay artifact's term must hold exactly the keys " <>
           "#{Enum.map_join(@keys, ", ", &"#{&1}:")}; missing: #{inspect(@keys -- keys)}, " <>
           "unknown: #{inspect(keys -- @keys)}"}

      not valid_targets?(term) ->
        {:error,
         "the replay artifact's targets: must be a non-empty list of " <>
           "%{name: name, expansion: mode} maps naming each target of choices: once"}

      true ->
        {:ok, term}
    end
  end

  defp valid_targets?(%{targets: [_ | _] = targets, choices: choices}) when is_map(choices) do
    names =
      for %{name: name, expansion: mode} <- targets, is_binary(name), is_atom(mode), do: name

    length(names) == length(targets) and Enum.sort(names) == Enum.sort(Map.keys(choices)) and
      Enum.all?(Map.values(choices), &valid_choices?/1)
  end

  defp valid_targets?(_term), do: false

  defp valid_choices?(choices) when is_list(choices),
    do: Enum.all?(choices, &(is_map(&1) and Enum.sort(Map.keys(&1)) == Enum.sort(@choice_keys)))

  defp valid_choices?(_choices), do: false

  defp walk(quoted) do
    {:ok, literal!(quoted)}
  catch
    {:refuse, node, why} -> {:error, "#{why}: #{source(node)} at line #{line(node)}"}
  end

  defp literal!({:__block__, _meta, [value]}), do: literal!(value)
  defp literal!(value) when is_atom(value) or is_number(value) or is_binary(value), do: value
  defp literal!(list) when is_list(list), do: Enum.map(list, &literal!/1)
  defp literal!({left, right}), do: {literal!(left), literal!(right)}

  defp literal!({:{}, _meta, items}) when is_list(items),
    do: List.to_tuple(Enum.map(items, &literal!/1))

  defp literal!({:-, _meta, [operand]} = node) do
    case literal!(operand) do
      number when is_number(number) -> -number
      _other -> refuse!(node)
    end
  end

  defp literal!({:<<>>, _meta, parts} = node) when is_list(parts) do
    bytes = Enum.map(parts, &literal!/1)

    if Enum.all?(bytes, &(is_integer(&1) and &1 in 0..255)),
      do: :erlang.list_to_binary(bytes),
      else: refuse!(node)
  end

  defp literal!({:__aliases__, _meta, parts} = node) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: refuse!(node)
  end

  defp literal!({:%{}, _meta, pairs} = node) when is_list(pairs) do
    map = Map.new(pairs, &pair!(&1, node))

    if Map.has_key?(map, :__struct__),
      do: throw({:refuse, node, "a map with a __struct__ key is not a literal"}),
      else: map
  end

  defp literal!({:%, _meta, [module_node, {:%{}, _, pairs}]} = node) when is_list(pairs) do
    module = literal!(module_node)
    fields = Enum.map(pairs, &pair!(&1, node))

    cond do
      not is_atom(module) ->
        refuse!(node)

      not Code.ensure_loaded?(module) ->
        throw({:refuse, node, "the struct module #{inspect(module)} is not loaded"})

      not function_exported?(module, :__struct__, 1) ->
        throw({:refuse, node, "#{inspect(module)} is not a struct"})

      true ->
        build_struct!(module, fields, node)
    end
  end

  defp literal!(node), do: refuse!(node)

  defp pair!({key, value}, _node), do: {literal!(key), literal!(value)}
  defp pair!(other, _node), do: refuse!(other)

  defp build_struct!(module, fields, node) do
    struct!(module, fields)
  rescue
    e in [ArgumentError, KeyError] ->
      throw(
        {:refuse, node,
         "the struct #{inspect(module)} cannot hold its fields (#{Exception.message(e)})"}
      )
  end

  defp refuse!(node), do: throw({:refuse, node, "not a literal"})

  # A node as source, without the literal wrappers the parser added.
  defp source(node) do
    node
    |> Macro.prewalk(fn
      {:__block__, _meta, [value]} -> value
      other -> other
    end)
    |> Macro.to_string()
  end

  defp line({_name, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, "?")
  defp line(_node), do: "?"

  # ==========================================================================
  # Re-executing
  # ==========================================================================

  @doc false
  # The sequence `term` records: the setup commands and the roots, with a
  # placeholder registry rebuilt by simulating them again at the positions
  # generation simulated them at (a root at the position of its root id), so
  # every placeholder the recorded commands hold resolves; then the teardown
  # commands generated from the seed against the state the roots leave.
  @spec sequence(t()) :: Sequence.t()
  def sequence(term) do
    roots = Enum.map(term.roots, & &1.command)
    sequence = %{Sequence.linear(roots) | setup: term.prefix, registry: registry(term)}
    Generator.teardown_commands(term.model, sequence, term.seed)
  end

  defp registry(%{model: model} = term) do
    projection = model.command_sequence_projection()

    steps =
      Enum.with_index(term.prefix, fn command, offset -> {command, Position.setup(offset)} end) ++
        Enum.map(term.roots, fn %{command: command, root_id: id} ->
          {command, Position.prefix(id)}
        end)

    {registry, _state} =
      Enum.reduce(steps, {PlaceholderRegistry.new(), projection.init()}, fn {command, position},
                                                                            {registry, state} ->
        {_command, _events, state, minted} =
          Generator.simulate_step(model, command, position, state)

        {Enum.reduce(minted, registry, &PlaceholderRegistry.register(&2, &1)), state}
      end)

    moved =
      term.roots
      |> Enum.with_index()
      |> Map.new(fn {%{root_id: id}, index} -> {Position.prefix(id), Position.prefix(index)} end)

    PlaceholderRegistry.remap_positions(registry, moved)
  end

  @doc false
  # Every recorded target's concrete sequence for `sequence(term)`, from the
  # commands it ran, with no draw: `PropertyDamage.Expansion.t()`, restricted
  # to `names` (default: every recorded target).
  @spec expansion(t(), Sequence.t(), [String.t()] | nil) :: Expansion.t()
  def expansion(term, %Sequence{} = sequence, names \\ nil) do
    recorded = if names, do: Map.take(term.choices, names), else: term.choices

    if Expansion.defines?(term.model) do
      Expansion.recorded(term.model, sequence, term.seed, recorded, owners(term))
    else
      Expansion.identity(sequence, Enum.map(Map.keys(recorded), &%{name: &1}))
    end
  end

  # The name each target's seed keys carry: a target that copied the
  # reference realized the reference's entries.
  defp owners(term) do
    reference = hd(term.targets).name

    Map.new(term.targets, fn
      %{name: name, expansion: :reference} -> {name, reference}
      %{name: name} -> {name, name}
    end)
  end

  @doc false
  # Whether `report` fails as the artifact `term` records: the same kind, the
  # same failure name, the same failing target (by name) and the same root.
  @spec reproduced?(t(), FailureReport.t()) :: boolean()
  def reproduced?(term, %FailureReport{} = report) do
    recorded_name =
      term.targets |> Enum.at(term.failure.variant_index || 0, %{}) |> Map.get(:name)

    report.kind == term.failure.kind and
      Failure.name(report.failure_reason) == term.failure.name and
      (report.variant && report.variant.name) == recorded_name and
      report.failed_at_index == term.failure.root_index
  end
end
