defmodule PropertyDamage.FailureReport.Bundle.Sources do
  @moduledoc false
  # The source members of a failure document: the docs and source file of
  # every module behind the failure, the files that could not be read and the
  # number of literals redacted. `PropertyDamage.FailureReport.Document`
  # writes them when it is built with `sources: true`; its moduledoc describes
  # each member.

  alias PropertyDamage.{Docs, Failure, FailureReport}
  alias PropertyDamage.FailureReport.Bundle.Redaction

  @doc """
  `{modules, missing_sources, redactions}` for the listed `targets`, whose
  adapters are `adapters` (each the root of a tree of sub-adapters).
  """
  @spec build(FailureReport.t(), [map()], [module()]) ::
          {[map()], [String.t()], non_neg_integer()}
  def build(report, targets, adapters) do
    steps = for target <- targets, step <- target.steps, do: step

    adapters = Enum.flat_map(adapters, &adapter_tree(&1, []))

    listed =
      [{FailureReport.model(report), :model}] ++
        Enum.map(projections(report), &{&1, :projection}) ++
        for(step <- steps, command = struct_module(step.command), do: {command, :command}) ++
        for(
          step <- steps,
          event <- step.events,
          module = struct_module(event),
          do: {module, :event}
        ) ++
        Enum.map(adapters, &{&1, :adapter})

    unique =
      listed
      |> Enum.filter(fn {module, _role} -> is_atom(module) and not is_nil(module) end)
      |> Enum.uniq_by(&elem(&1, 0))

    adapter_files = adapter_files(adapters)
    built = Enum.map(unique, fn {module, role} -> module_entry(module, role, adapter_files) end)

    missing = built |> Enum.flat_map(& &1.missing) |> Enum.uniq()
    redacted = built |> Enum.map(& &1.entry["redactions"]) |> Enum.sum()

    {Enum.map(built, & &1.entry), missing, redacted}
  end

  # The adapter followed by the modules its `delegate_execution` calls name,
  # depth first, each once. An adapter without `__pd_sub_adapters__/0` (a
  # bare `@behaviour`) has none.
  defp adapter_tree(adapter, seen) do
    if adapter in seen or not is_atom(adapter) or is_nil(adapter) do
      []
    else
      [adapter | sub_adapters(adapter) |> Enum.flat_map(&adapter_tree(&1, [adapter | seen]))]
    end
  end

  defp sub_adapters(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :__pd_sub_adapters__, 0),
      do: adapter.__pd_sub_adapters__(),
      else: []
  end

  # The source files that define the adapter of a listed target, whatever
  # role the module is listed under. Every module defined in one of them
  # shows the same text.
  defp adapter_files(adapters) do
    for module <- adapters,
        is_atom(module),
        {:ok, %{file: file}} when is_binary(file) <- [Docs.fetch(module)],
        into: MapSet.new(),
        do: file
  end

  defp struct_module(%module{}), do: module
  defp struct_module(_other), do: nil

  defp projections(%FailureReport{} = report) do
    model = FailureReport.model(report)
    reason = FailureReport.failure_reason(report)

    checks =
      case exported(model, :check_projections) do
        modules when is_list(modules) -> modules
        _none -> []
      end

    sequence = exported(model, :command_sequence_projection)

    failed =
      case reason do
        %Failure{type: %Failure.Check{projection: projection}} -> projection
        _other -> nil
      end

    (checks ++ [sequence, failed])
    |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
    |> Enum.uniq()
  end

  defp exported(model, function) when is_atom(model) and not is_nil(model) do
    if Code.ensure_loaded?(model) and function_exported?(model, function, 0),
      do: apply(model, function, []),
      else: nil
  rescue
    _error -> nil
  end

  defp exported(_model, _function), do: nil

  defp module_entry(module, role, adapter_files) do
    base = %{"module" => inspect(module), "role" => to_string(role)}

    case Docs.fetch(module) do
      {:ok, docs} -> entry_from_docs(base, module, adapter_files, docs)
      :unavailable -> unavailable(base)
    end
  end

  defp unavailable(base) do
    entry =
      Map.merge(base, %{
        "moduledoc" => nil,
        "file" => nil,
        "lines" => nil,
        "source" => nil,
        "resolution" => "unavailable",
        "functions" => [],
        "redactions" => 0
      })

    %{entry: entry, missing: []}
  end

  # A module compiled from a string reports the file "nofile": no file.
  defp entry_from_docs(base, module, adapter_files, %{file: "nofile"} = docs),
    do: entry_from_docs(base, module, adapter_files, %{docs | file: nil})

  defp entry_from_docs(base, module, adapter_files, %{file: file} = docs) do
    {text, missing} = read(file)
    {source, redactions} = source_of(text, file, adapter_files)
    ranges = if text, do: ranges(text, module), else: %{}

    entry =
      Map.merge(base, %{
        "moduledoc" => docs.moduledoc,
        "file" => shown_path(file),
        "lines" => text && line_count(text),
        "source" => source,
        "resolution" => resolution(module, file),
        "functions" => functions(module, docs.functions, ranges),
        "redactions" => redactions
      })

    %{entry: entry, missing: missing}
  end

  defp read(nil), do: {nil, []}

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> {text, []}
      {:error, _reason} -> {nil, [shown_path(file)]}
    end
  end

  # The path a page shows for a source file: relative to the project root
  # (the current directory), so a shared page does not reveal the local
  # directory names; a file outside the project shows its base name only.
  defp shown_path(nil), do: nil

  defp shown_path(file) do
    root = File.cwd!()
    path = Path.expand(file)

    if String.starts_with?(path, root <> "/"),
      do: Path.relative_to(path, root),
      else: Path.basename(path)
  end

  defp source_of(nil, nil, _adapter_files), do: {nil, 0}
  defp source_of(nil, file, _adapter_files), do: {%{"missing" => shown_path(file)}, 0}

  defp source_of(text, file, adapter_files) do
    if MapSet.member?(adapter_files, file), do: Redaction.redact(text), else: {text, 0}
  end

  # A module without a source file has no source to show, whatever docs it
  # has.
  defp resolution(_module, nil), do: "unavailable"

  defp resolution(module, _file) do
    if match?(%{functions: _}, captured(module)), do: "captured", else: "beam"
  end

  defp captured(module) do
    if function_exported?(module, :__pd_docs__, 0), do: module.__pd_docs__()
  end

  # The line count of an editor: a last line without a newline counts.
  defp line_count(""), do: 0

  defp line_count(text) do
    count = text |> String.split("\n") |> length()
    if String.ends_with?(text, "\n"), do: count - 1, else: count
  end

  defp functions(module, docs, ranges) do
    docs
    |> Enum.sort_by(fn {{name, arity}, %{line: line}} -> {line, name, arity} end)
    |> Enum.map(fn {{name, arity}, %{doc: doc, line: line}} ->
      range = Map.get(ranges, {name, arity})
      {from, to} = range(range, line)

      %{
        "id" => source_id(module, name, arity, range),
        "name" => to_string(name),
        "arity" => arity,
        "doc" => doc,
        "from" => from,
        "to" => to
      }
    end)
  end

  # A function without lines to cite has no id: a macro injected it, or the
  # file of its module is missing, unreadable or "nofile".
  defp source_id(_module, _name, _arity, nil), do: nil
  defp source_id(module, name, arity, _range), do: "source:#{inspect(module)}.#{name}/#{arity}"

  # `clauses` is `[{first_line, last_line}]` of the function's clauses. The
  # range starts at the first clause at or after the line the docs report.
  defp range(nil, _line), do: {nil, nil}

  defp range(clauses, line) do
    {from, _to} = Enum.find(clauses, hd(clauses), fn {start, _stop} -> start >= line end)
    {_start, to} = List.last(clauses)
    {from, to}
  end

  # ==========================================================================
  # Function ranges
  # ==========================================================================

  @definitions [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard, :defguardp]

  # `%{{name, arity} => [{first_line, last_line}]}` for the clauses the file
  # defines at the top level of `module`. A clause ends the line before the
  # next definition of the module, and the last one the line before the
  # module's `end`. A file that does not parse gives no ranges.
  defp ranges(text, module) do
    with {:ok, ast} <- Code.string_to_quoted(text, token_metadata: true),
         {body, limit} <- find_module(ast, module, []) do
      clauses = for expr <- block(body), clause <- clause(expr), do: clause
      starts = Enum.map(clauses, &elem(&1, 0))

      clauses
      |> Enum.map(fn {start, keys} ->
        stop = (Enum.find(starts, &(&1 > start)) || limit) - 1
        {keys, {start, stop}}
      end)
      |> Enum.flat_map(fn {keys, range} -> Enum.map(keys, &{&1, range}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {key, ranges} -> {key, Enum.sort(ranges)} end)
    else
      _unreadable -> %{}
    end
  rescue
    # An unexpected shape gives no ranges: the page is still written.
    _shape -> %{}
  end

  defp block({:__block__, _meta, expressions}), do: expressions
  defp block(nil), do: []
  defp block(expression), do: [expression]

  # The line of a definition and the `{name, arity}` keys it defines: one
  # per arity that default arguments add.
  defp clause({kind, meta, [head | _]}) when kind in @definitions do
    case head_key(head) do
      {name, arity, defaults} ->
        [{meta[:line], for(a <- (arity - defaults)..arity, do: {name, a})}]

      nil ->
        []
    end
  end

  defp clause(_expression), do: []

  defp head_key({:when, _meta, [head | _guards]}), do: head_key(head)

  defp head_key({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), Enum.count(args, &match?({:\\, _, _}, &1))}

  defp head_key({name, _meta, nil}) when is_atom(name), do: {name, 0, 0}
  defp head_key(_head), do: nil

  # The body of the `defmodule` that defines `module` and the first line
  # after it, found at any depth; a nested module takes the name of its
  # parents. A module written as `defmodule M, do: ...` has no `end`: it
  # stops after the last line its expression reaches.
  defp find_module({:defmodule, meta, [{:__aliases__, _, parts}, [do: body]]}, module, parents) do
    name = module_parts(parts, parents)

    if Module.concat(name) == module,
      do: {body, after_module(meta, body)},
      else: find_module(body, module, name)
  end

  defp find_module({_form, _meta, args}, module, parents) when is_list(args),
    do: find_module(args, module, parents)

  defp find_module(list, module, parents) when is_list(list),
    do: Enum.find_value(list, &find_module(&1, module, parents))

  defp find_module({left, right}, module, parents),
    do: find_module([left, right], module, parents)

  defp find_module(_other, _module, _parents), do: nil

  defp after_module(meta, body) do
    case meta[:end][:line] do
      nil -> last_line(body) + 1
      end_line -> end_line
    end
  end

  # The last line the module's definitions reach: a `do ... end` call ends on
  # its `end` and a call in parentheses on its closing one. The parentheses
  # around the whole body are not a definition, so their line is not counted.
  defp last_line(body) do
    {_ast, last} =
      Macro.prewalk(block(body), 0, fn
        {_form, meta, _args} = node, last when is_list(meta) ->
          {node,
           Enum.max([last, meta[:line] || 0, meta[:end][:line] || 0, meta[:closing][:line] || 0])}

        node, last ->
          {node, last}
      end)

    last
  end

  defp module_parts([{:__MODULE__, _, _} | rest], parents), do: parents ++ rest
  defp module_parts(parts, parents), do: parents ++ parts
end
