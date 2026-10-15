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
  # accepts literals only. Nothing in the file is ever evaluated, and reading
  # it neither creates an atom nor loads a module: an atom the running system
  # does not know is refused. A struct literal in a command's own place (an
  # element of `prefix`, a root's `command`, an element of a choice's
  # `commands`) loads only when its module is already loaded and is a command
  # module or one of the structs the format itself holds (`@format_structs`).
  # Anywhere else, at any depth of a command's fields, a struct literal loads
  # when its module is already loaded; any other struct is refused naming its
  # module.
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
  # The framework's own structs an artifact holds: a placeholder minted for
  # an `external()` field and the positions inside it and in `aliases`.
  @format_structs [PropertyDamage.Placeholder, PropertyDamage.Sequence.Position]
  # Every static atom of the source is parsed as `{@atom_tag, name}` and
  # resolved to an existing atom afterwards; the source cannot write this
  # pair itself, since its own atoms are parsed the same way.
  @atom_tag :"$replay_artifact_atom"
  @alias_tag :"$replay_artifact_alias"
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
  an integer, a map key as the key). A map key that is itself such a value,
  or holds one, is marked `{:key, text}`, with the key as `inspect/2` shows
  it: `[:payload, {:key, "#PID<0.105.0>"}]` names a pid used as a key of the
  `payload` map. A `MapSet` is walked through the map it keeps, so its
  elements are keys under `:map`. A setup command is named by `root:
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

  # A map's keys are walked as its values are: a key no literal can hold, or
  # one holding such a value, is marked `{:key, text}` in the path, the text
  # being the key as `inspect/2` shows it.
  defp unprintable(map, path) when is_map(map) do
    map
    |> Enum.sort()
    |> Enum.find_value(fn {key, value} ->
      key_refusal(key, path) || unprintable(value, [key | path])
    end)
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

  defp key_refusal(key, path) do
    case unprintable(key, []) do
      nil -> nil
      inside -> Enum.reverse(path, [{:key, inspect(key, limit: 8)} | inside])
    end
  end

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

  # `[:payload, 0, :f]` as `payload[0].f`, and a marked key as `[key text]`.
  defp field_text(field) do
    field
    |> Enum.map_join(fn
      key when is_integer(key) -> "[#{key}]"
      key when is_atom(key) -> ".#{key}"
      {:key, text} when is_binary(text) -> "[key #{text}]"
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
  # Writes `term` into `dir` (created when missing). The file is
  # `file_name(term)`, replaced when it holds the same failure (the same kind,
  # name and failing target) under the same targets, as a re-shrink of that
  # failure writes, or when it does not read as an artifact. A file holding
  # another failure or other targets is never replaced: the term goes to
  # `<Model>_seed<n>_<k>.replay.exs`, the smallest `k` from 2 whose file is
  # free, holds the same failure or is no artifact. Returns `{:ok, path}` or
  # `{:error, reason}`.
  @spec write(t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(term, dir) do
    path = free_path(term, dir)

    with {:mkdir, :ok} <- {:mkdir, File.mkdir_p(dir)},
         {:write, :ok} <- {:write, File.write(path, encode(term))} do
      {:ok, path}
    else
      {:mkdir, {:error, reason}} -> {:error, {:mkdir_failed, dir, reason}}
      {:write, {:error, reason}} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp free_path(term, dir) do
    base = Path.rootname(file_name(term), ".replay.exs")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> Path.join(dir, base <> ".replay.exs")
      k -> Path.join(dir, "#{base}_#{k}.replay.exs")
    end)
    |> Enum.find(&writable?(&1, term))
  end

  # A path the term may be written to: no file there, one recording the same
  # failure under the same targets, or one that is no artifact at all (it
  # records no failure to keep).
  defp writable?(path, term) do
    case read(path) do
      {:ok, existing} -> same_failure?(existing, term)
      {:error, _reason} -> true
    end
  end

  defp same_failure?(existing, term) do
    existing.targets == term.targets and
      Map.take(existing.failure, [:kind, :name, :variant_index]) ==
        Map.take(term.failure, [:kind, :name, :variant_index])
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
  # The term the artifact at `path` holds, read as data. A refusal is a
  # message, or `{:unknown_struct_module, module}` for a struct literal whose
  # module is not loaded, or, in a command's own place, is neither a command
  # module nor a format struct.
  @spec read(Path.t()) ::
          {:ok, t()} | {:error, String.t() | {:unknown_struct_module, module()}}
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
  @spec parse(String.t()) ::
          {:ok, t()} | {:error, String.t() | {:unknown_struct_module, module()}}
  def parse(text) when is_binary(text) do
    with :ok <- check_header(text),
         {:ok, quoted} <- quote_text(text),
         {:ok, term} <- walk(quoted, text),
         :ok <- check_commands(term),
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
    opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      existing_atoms_only: true,
      static_atoms_encoder: fn name, _meta -> {:ok, {@atom_tag, name}} end,
      emit_warnings: false
    ]

    case Code.string_to_quoted(text, opts) do
      {:ok, {:__block__, _meta, [_first, second | _rest]}} ->
        second = resolve_atoms(second)

        {:error,
         "the replay artifact holds a second term, #{source(second, text)}, at line " <>
           "#{line(second)}: an artifact holds one term"}

      {:ok, quoted} ->
        {:ok, resolve_atoms(quoted)}

      {:error, {meta, "unsafe atom does not exist: " <> _, token}} ->
        {:error, unknown_atom(token, Keyword.get(meta, :line, "?"))}

      {:error, {meta, message, token}} ->
        {:error,
         "the replay artifact is not valid Elixir at line #{Keyword.get(meta, :line, "?")}: " <>
           "#{inspect(message)} #{inspect(token)}"}
    end
  end

  # Every struct in a command's own place must be a command or a format
  # struct; the walker already built it, so its module is loaded.
  defp check_commands(term) do
    Enum.find_value(commands(term), :ok, fn
      %module{} -> if not command_struct?(module), do: {:error, {:unknown_struct_module, module}}
      _other -> nil
    end)
  end

  defp commands(term) when is_map(term) do
    roots = for %{command: command} <- items(Map.get(term, :roots)), do: command
    choices = Map.get(term, :choices)
    entries = if is_map(choices), do: Enum.flat_map(Map.values(choices), &items/1), else: []
    leaves = for %{commands: commands} <- entries, command <- items(commands), do: command
    items(Map.get(term, :prefix)) ++ roots ++ leaves
  end

  defp commands(_term), do: []

  defp items(list) when is_list(list), do: list
  defp items(_other), do: []

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

  defp walk(quoted, text) do
    {:ok, literal!(quoted)}
  catch
    {:refuse, node, why} -> {:error, "#{why}: #{source(node, text)} at line #{line(node)}"}
    {:unknown_atom, name, line} -> {:error, unknown_atom(name, line)}
    {:unknown_struct_module, module} -> {:error, {:unknown_struct_module, module}}
  end

  defp unknown_atom(name, line),
    do:
      "the replay artifact names #{name}, which this system does not know (no such atom), " <>
        "at line #{line}"

  # Every tagged atom the running system knows becomes that atom; an alias
  # becomes its module when that module's name is an atom already. Anything
  # else stays tagged, and the walker refuses it naming the source.
  defp resolve_atoms(quoted) do
    Macro.prewalk(quoted, fn
      {:__aliases__, meta, parts} = node when is_list(parts) ->
        case alias_names(parts) do
          nil -> node
          names -> {:__aliases__, meta, resolve_alias(names)}
        end

      {@atom_tag, name} = node when is_binary(name) ->
        case existing_atom(name) do
          {:ok, atom} -> atom
          :error -> node
        end

      other ->
        other
    end)
  end

  defp alias_names(parts) do
    if Enum.all?(parts, &match?({@atom_tag, name} when is_binary(name), &1)),
      do: Enum.map(parts, &elem(&1, 1))
  end

  # The segments as atoms when every one is an atom already (so the source
  # prints as written), else the module alone; `{@alias_tag, name}` when the
  # module's name is no atom at all.
  defp resolve_alias(names) do
    with {:ok, _module} <- existing_atom("Elixir." <> Enum.join(names, ".")),
         segments = Enum.map(names, &existing_atom/1),
         true <- Enum.all?(segments, &match?({:ok, _}, &1)) do
      Enum.map(segments, &elem(&1, 1))
    else
      :error -> [{@alias_tag, Enum.join(names, ".")}]
      false -> [String.to_existing_atom("Elixir." <> Enum.join(names, "."))]
    end
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp literal!({:__block__, meta, [{@atom_tag, name}]}) when is_binary(name),
    do: throw({:unknown_atom, ":" <> inspect(name), Keyword.get(meta, :line, "?")})

  defp literal!({@atom_tag, name}) when is_binary(name),
    do: throw({:unknown_atom, ":" <> inspect(name), "?"})

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

  defp literal!({:__aliases__, meta, [{@alias_tag, name}]}),
    do: throw({:unknown_atom, name, Keyword.get(meta, :line, "?")})

  defp literal!({:__aliases__, _meta, parts} = node) when is_list(parts) do
    with true <- Enum.all?(parts, &is_atom/1),
         {:ok, module} <- existing_atom(module_name(parts)) do
      module
    else
      _not_a_module -> refuse!(node)
    end
  end

  defp literal!({:%{}, _meta, pairs} = node) when is_list(pairs) do
    map = Map.new(pairs, &pair!(&1, node))

    if Map.has_key?(map, :__struct__),
      do: throw({:refuse, node, "a map with a __struct__ key is not a literal"}),
      else: map
  end

  defp literal!({:%, _meta, [module_node, {:%{}, _, pairs}]} = node) when is_list(pairs) do
    module = literal!(module_node)

    cond do
      not is_atom(module) ->
        refuse!(node)

      not artifact_struct?(module) ->
        throw({:unknown_struct_module, module})

      true ->
        build_struct!(module, Enum.map(pairs, &pair!(&1, node)), node)
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

  defp module_name(parts) do
    case Enum.map_join(parts, ".", &Atom.to_string/1) do
      "Elixir." <> _ = name -> name
      name -> "Elixir." <> name
    end
  end

  # A struct module an artifact may name: one loaded before the artifact is
  # read (the loader never loads a module) that defines a struct.
  defp artifact_struct?(module),
    do: :code.is_loaded(module) != false and function_exported?(module, :__struct__, 1)

  # A struct module a command's own place may name: a command module or one of
  # the format's own structs.
  defp command_struct?(module),
    do: module in @format_structs or function_exported?(module, :generator, 1)

  defp refuse!(node), do: throw({:refuse, node, "not a literal"})

  # A node as source, without the literal wrappers the parser added. A node
  # naming an atom the system does not know cannot be printed as source; its
  # line of the file stands for it.
  defp source(node, text) do
    unwrapped =
      Macro.prewalk(node, fn
        {:__block__, _meta, [value]} -> value
        other -> other
      end)

    if tagged?(unwrapped), do: line_text(node, text), else: Macro.to_string(unwrapped)
  end

  defp tagged?(node) do
    {_node, found?} =
      Macro.prewalk(node, false, fn
        {tag, name} = pair, _found when tag in [@atom_tag, @alias_tag] and is_binary(name) ->
          {pair, true}

        other, found ->
          {other, found}
      end)

    found?
  end

  defp line_text(node, text) do
    case line(node) do
      line when is_integer(line) ->
        text |> String.split("\n") |> Enum.at(line - 1, "") |> String.trim()

      _unknown ->
        "a node naming an unknown atom"
    end
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
    registry = registry(term.model, term.prefix, term.roots)
    sequence = %{Sequence.linear(roots) | setup: term.prefix, registry: registry}
    Generator.teardown_commands(term.model, sequence, term.seed)
  end

  @doc false
  # The placeholder ids that `commands` hold and that the registry an
  # artifact recording `prefix` and `roots` (`[%{root_id:, command:}]`) would
  # rebuild does not register, in the order the commands hold them. An id a
  # leaf mints is left out: a re-execution simulates the leaves again where
  # they ran, so it mints that id again. A shrink candidate with an id here
  # would fail on replay where it failed in the shrink, so the shrinker never
  # runs it.
  @spec unregistered(module(), [struct()], [map()], [struct()]) :: [term()]
  def unregistered(model, prefix, roots, commands) do
    registry = registry(model, prefix, roots)

    commands
    |> PlaceholderRegistry.collect_placeholder_ids()
    |> Enum.reject(fn id ->
      match?({%Position{section: {:leaf, _}}, _event, _path}, id) or
        PlaceholderRegistry.get(registry, id) != nil
    end)
  end

  # The registry the recorded commands resolve against: the setup commands
  # and the roots simulated again from the projection's initial state, each
  # root at the position of its root id, then moved to the roots' positions
  # in the recorded order.
  defp registry(model, prefix, roots) do
    projection = model.command_sequence_projection()

    steps =
      Enum.with_index(prefix, fn command, offset -> {command, Position.setup(offset)} end) ++
        Enum.map(roots, fn %{command: command, root_id: id} ->
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
      roots
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
      Expansion.identity(
        sequence,
        Enum.map(Map.keys(recorded), &%{name: &1}),
        Enum.map(term.roots, & &1.root_id)
      )
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
  # What the targets named `names` ran in the run `report` describes, for a
  # path that re-executes it (`path` names that path in an error):
  # `{sequence, variants}`, with `variants` mapping each name to its choices
  # and the registry its commands resolve against, or nil for a model without
  # `expansions/0`, whose targets run the roots as themselves. The report's
  # `replay` term is read first: the sequence and every target's commands are
  # rebuilt from it with no draw. A report without one (an artifact refused
  # for a value no file can hold, say) falls back to the choices its trace
  # records. Raises `ArgumentError` naming `path` when the report records
  # neither a `replay` term nor `expansions`, or does not record what one of
  # `names` ran.
  @spec reexecution(FailureReport.t(), [String.t()], String.t()) ::
          {Sequence.t(), %{String.t() => map()} | nil}
  def reexecution(%FailureReport{model: model} = report, names, path) do
    cond do
      not Expansion.defines?(model) ->
        {FailureReport.shrunk_sequence(report), nil}

      is_map(report.replay) ->
        from_term(report.replay, names, path)

      is_nil(report.replay) and is_nil(report.expansions) ->
        raise ArgumentError,
              "#{path} rebuilds what each target ran from the report's `replay` term or its " <>
                "`expansions`, and this report holds neither, while #{inspect(model)} defines " <>
                "expansions/0. A failing run records both, and writes the same term into its " <>
                "`replay_dir:` (`only: [replay: path]` replays that file); run the failing " <>
                "seed again to get a report that records them"

      true ->
        from_trace(report, names, path)
    end
  end

  defp from_term(term, names, path) do
    case names -- Map.keys(term.choices) do
      [] ->
        sequence = sequence(term)
        {sequence, expansion(term, sequence, names).variants}

      missing ->
        raise ArgumentError,
              "#{path} re-executes the failure from the report's replay term, which records " <>
                "what #{Enum.map_join(Map.keys(term.choices), ", ", &inspect/1)} ran, not " <>
                "#{Enum.map_join(missing, ", ", &inspect/1)}; re-execute it on the targets " <>
                "the report records"
    end
  end

  defp from_trace(report, names, path) do
    traced = Expansion.traced!(report.model, report.trace && report.trace.expansion, names, path)
    sequence = FailureReport.shrunk_sequence(report)

    {sequence,
     Map.new(names, fn name ->
       {name, Expansion.carried(report.model, sequence, Map.fetch!(traced, name))}
     end)}
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
