defmodule PropertyDamage.FailureReport.Bundle do
  @moduledoc """
  A machine-readable copy of a failure report's structure, docs and sources.

  `build/2` returns a JSON-ready map that every HTML failure page carries in a
  script tag with the id `pd-bundle`, next to the page's own text. A program
  that reads a page gets, without parsing the terminal text, the failure's
  fields, the steps and events of each target's listing, the sections, the
  docs and source file of every module behind the failure, and an id for each
  thing a reader may cite. The bundle never copies the page's step, event or
  section text: it names them by id and the page prints them.

  The map is deterministic: no timestamp, no process id, a stable order
  everywhere. `opts` are the options the page's layout received (`log:`), so
  the bundle describes the listing the page shows.

  ## Keys

  | key | type | meaning |
  |---|---|---|
  | `format` | integer | the bundle format, `1` |
  | `pd_version` | string | the version of this library |
  | `failure` | map | `kind`, `meaning` (the text the kind prints under "What this checks") and `fields`: the Failure section's lines, each `{id, label, value}` in print order |
  | `context` | list | the items of "What this checks", each `{id, label, name, text, missing}` |
  | `listing` | list | one map per target, the reference first (see below) |
  | `sections` | list | one `{id, title, fence, data}` per `## ` section, in page order |
  | `modules` | list | one map per module behind the failure (see below) |
  | `ids` | list | every id the bundle declares, once each, in a stable order |
  | `missing_sources` | list | the paths of source files that could not be read |
  | `redactions` | map | `count` of literals replaced in the sources of the modules in adapter files, and the `rule` applied |

  ### Listing

  A target is `{name, role, adapter, steps, adapter_setup, adapter_teardown,
  untied}`. `role` is `"variant"` or `"reference"`, and `adapter` is the
  module as `inspect/1` prints it. A step is `{id, label, command, ran_as,
  failed, entries}`: `label` is the label the page prints (`[3]`, `[setup 0]`,
  `[branch 0.1]`), `command` the module of the command, `ran_as` the note
  that names the expansion entry a root ran as (else `null`), and `failed`
  marks the step the failure is reported at. An entry is `{id, n, event}`:
  `n` counts the events under the step from 1, in print order, after the log
  filter, and `event` is the module of the event struct (`null` for another
  term). Log lines are not entries.

  The lines under the adapter's `setup/1` and `teardown/1` notes and the
  events tied to no command belong to no step. `adapter_setup`,
  `adapter_teardown` and `untied` count them, each as `{count, section}`,
  where `section` is the id of the section that prints them.

  ### Sections

  `data` is `null` except for three sections:

    * "Setup": `{commands: [{label, command}]}`, the setup commands of the
      run;
    * "Projections at ...": `{projections: [{name, before, at_failure,
      reference}]}`; a comparison fills `at_failure` (the variant) and
      `reference`, any other failure fills `before` and `at_failure`. A value
      is JSON when Jason can encode the state, else `{"inspect": text}`;
    * "Reproduction": `{roots: [{label, command}], seed, command}`, where
      `command` reruns the failure with the targets bound to a variable, so
      no target config value is copied.

  ### Modules

  The model, then its projections (`check_projections/0`,
  `command_sequence_projection/0` and the projection of a failed check), then
  the commands of every listed step, the event structs of every entry and the
  adapter of every target, each module once, in that order. A module is
  `{module, role, moduledoc, file, lines, source, resolution, functions,
  redactions}`:

    * `role` is `model`, `projection`, `command`, `event` or `adapter`;
    * `resolution` is `captured` when `PropertyDamage.Docs.fetch/1` read the
      docs from `__pd_docs__/0`, `beam` when it read the beam's docs chunk,
      and `unavailable` when it found no docs or the module has no source
      file (a module compiled from a string reports the file `"nofile"`,
      which counts as none);
    * `source` is the full text of `file`, `{"missing": path}` when the file
      cannot be read (the path is also in `missing_sources`), and `null` for
      a module without a file; `lines` is the file's line count;
    * a function is `{id, name, arity, doc, from, to}` (`id` may be `null`, see "Ids").

  ### Function ranges

  The ranges come from the file's syntax tree, read with
  `Code.string_to_quoted/2`, not from the docs. `from` is the line of the
  function's first clause, never its `@doc` line: the beam's docs chunk
  reports the `@doc` line, so `from` is the first clause at or after the
  reported line. `to` is the line before the next function definition of the
  module, private ones included, and the last definition runs to the line
  before the module's closing `end`; a module written as `defmodule M, do: ...`
  has no `end`, so its last definition runs to the last line the module's
  expression reaches. A module whose syntax tree has an unexpected shape gives
  no ranges, so its functions get a `null` id. A function the file does not define at
  the top level of its module (one a macro injects, or one generated in a
  loop) has `null` for both, as has every function of an
  unreadable file.

  ### Ids

  Ids are opaque: a reader finds one by equality in `ids` and never splits
  it. `failure:<label>` and `context:<label>` use the label as printed; a
  label that repeats gets an ordinal from the second occurrence (`:2`).
  `step:<target>:<label>`, `entry:<target>:<label>:<n>` and `section:<title>`
  use the text the page prints. `source:<Module>.<function>/<arity>` names a
  function `PropertyDamage.Docs.fetch/1` lists, private ones included. A
  function of a readable file that the file does not define at the top level
  of its module (one a macro injects, such as `timeout/1`) has `null` for its
  id and is not in `ids`: an id the bundle declares must point at lines a reader can check. A
  function of a module whose file could not be read keeps its id.

  ### Redaction

  The source of every module whose `file` is the file of an adapter in the
  bundle passes through `PropertyDamage.FailureReport.Bundle.Redaction`, which
  replaces secret-shaped string literals. A file shows the same text through
  each module defined in it, so a model above an adapter in one file is
  redacted too. Each module's `redactions` counts its own replacements and
  the top-level count sums them, so a literal in a shared file counts once
  per module that shows the file. The source of a module in a file no adapter
  shares is not scanned.
  """

  alias PropertyDamage.{Docs, Failure, FailureReport, Target}
  alias PropertyDamage.FailureReport.Bundle.Redaction
  alias PropertyDamage.FailureReport.{Context, Layout}

  @doc """
  Returns the bundle of `report` as a map with string keys.

  `opts` are the options the layout of the page takes, such as `log:`.
  """
  @spec build(FailureReport.t(), keyword()) :: map()
  def build(%FailureReport{} = report, opts \\ []) do
    data = Layout.bundle_data(report, opts)
    sections = data.layout.sections
    listing_id = listing_section_id(sections)

    failure = failure(report, sections, data.context)
    context = context(data.context)
    listing = Enum.map(data.targets, &target(&1, report, listing_id))
    section_entries = Enum.map(sections, &section(&1, data))
    {modules, missing, redacted} = modules(report, data.targets)

    ids =
      Enum.uniq(
        Enum.map(failure["fields"], & &1["id"]) ++
          Enum.map(context, & &1["id"]) ++
          listing_ids(listing) ++
          Enum.map(section_entries, & &1["id"]) ++
          for(
            module <- modules,
            %{"id" => id} <- module["functions"],
            is_binary(id),
            do: id
          )
      )

    %{
      "format" => 1,
      "pd_version" => to_string(Application.spec(:property_damage, :vsn)),
      "failure" => failure,
      "context" => context,
      "listing" => listing,
      "sections" => section_entries,
      "modules" => modules,
      "ids" => ids,
      "missing_sources" => missing,
      "redactions" => %{"count" => redacted, "rule" => Redaction.rule()}
    }
  end

  # ==========================================================================
  # Failure and context
  # ==========================================================================

  defp failure(report, sections, [meaning | _]) do
    fields =
      for %{heading: "Failure", lines: lines} <- sections,
          {:field, _, _} = line <- lines,
          do: line

    ids = fields |> Enum.map(fn {:field, label, _parts} -> label end) |> with_ordinals()

    %{
      "kind" => report |> FailureReport.failure_type() |> to_string(),
      "meaning" => meaning.text |> String.split() |> Enum.join(" "),
      "fields" =>
        for {{:field, label, parts}, id} <- Enum.zip(fields, ids) do
          %{"id" => "failure:" <> id, "label" => label, "value" => value_text(parts)}
        end
    }
  end

  defp value_text(parts) do
    Enum.map_join(parts, fn
      {:value, term} -> inspect(term, limit: :infinity, printable_limit: :infinity)
      text -> text
    end)
  end

  defp context(items) do
    ids = items |> Enum.map(& &1.label) |> with_ordinals()

    for {item, id} <- Enum.zip(Context.data(items), ids),
        do: Map.put(item, "id", "context:" <> id)
  end

  # The first occurrence of a label stays bare; later ones count from 2.
  defp with_ordinals(labels) do
    {ids, _seen} =
      Enum.map_reduce(labels, %{}, fn label, seen ->
        n = Map.get(seen, label, 0) + 1
        {if(n == 1, do: label, else: "#{label}:#{n}"), Map.put(seen, label, n)}
      end)

    ids
  end

  # ==========================================================================
  # Listing
  # ==========================================================================

  defp listing_section_id(sections) do
    Enum.find_value(sections, fn %{heading: heading} ->
      String.starts_with?(heading, "Minimal Reproduction") && "section:" <> heading
    end)
  end

  defp target(target, report, section_id) do
    name = target.name

    steps =
      for step <- target.steps do
        entries =
          for {event, n} <- Enum.with_index(step.events, 1) do
            %{
              "id" => "entry:#{name}:#{step.label}:#{n}",
              "n" => n,
              "event" => module_name(event)
            }
          end

        %{
          "id" => "step:#{name}:#{step.label}",
          "label" => step.label,
          "command" => module_name(step.command),
          "ran_as" => step.ran_as,
          "failed" => step.failed?,
          "entries" => entries
        }
      end

    %{
      "name" => name,
      "role" => to_string(target.role),
      "adapter" => report |> adapter_of(name) |> module_name(),
      "steps" => steps,
      "adapter_setup" => count(target.adapter_setup, section_id),
      "adapter_teardown" => count(target.adapter_teardown, section_id),
      "untied" => count(target.untied, section_id)
    }
  end

  defp count(n, section_id), do: %{"count" => n, "section" => section_id}

  defp listing_ids(listing) do
    for target <- listing,
        step <- target["steps"],
        id <- [step["id"] | Enum.map(step["entries"], & &1["id"])],
        do: id
  end

  # The adapter module of the target the listing names, from the targets the
  # run was given.
  defp adapter_of(%FailureReport{targets: targets}, name) do
    Enum.find_value(targets || [], fn
      {adapter, entry} -> target_name(adapter, entry) == name && adapter
      adapter when is_atom(adapter) -> Target.default_name(adapter) == name && adapter
      _other -> false
    end)
  end

  defp target_name(adapter, entry), do: Keyword.get(entry, :name) || Target.default_name(adapter)

  defp module_name(%module{}), do: inspect(module)
  defp module_name(module) when is_atom(module) and not is_nil(module), do: inspect(module)
  defp module_name(_other), do: nil

  # ==========================================================================
  # Sections
  # ==========================================================================

  defp section(section, data) do
    %{
      "id" => "section:" <> section.heading,
      "title" => section.heading,
      "fence" => section.fence,
      "data" => section_data(section.heading, data)
    }
  end

  defp section_data("Setup", data) do
    %{
      "commands" =>
        for(
          %{label: label, command: command} <- data.setup_commands,
          do: %{"label" => label, "command" => module_name(command)}
        )
    }
  end

  defp section_data("Projections at " <> _, data) do
    %{
      "projections" =>
        for projection <- data.projections do
          %{
            "name" => projection.name,
            "before" => json(projection.before),
            "at_failure" => json(projection.at_failure),
            "reference" => json(projection.reference)
          }
        end
    }
  end

  defp section_data("Reproduction", %{reproduction: reproduction}) do
    %{
      "roots" =>
        for(
          %{label: label, command: command} <- reproduction.roots,
          do: %{"label" => label, "command" => module_name(command)}
        ),
      "seed" => reproduction.seed,
      "command" => reproduction.command
    }
  end

  defp section_data(_heading, _data), do: nil

  # A value Jason can encode stays JSON; any other prints as `inspect/2` does.
  defp json(term) do
    term |> Jason.encode!() |> Jason.decode!()
  rescue
    _cannot_encode -> %{"inspect" => inspect(term, limit: :infinity, printable_limit: :infinity)}
  end

  # ==========================================================================
  # Modules
  # ==========================================================================

  defp modules(report, targets) do
    steps = for target <- targets, step <- target.steps, do: step

    listed =
      [{report.model, :model}] ++
        Enum.map(projections(report), &{&1, :projection}) ++
        for(step <- steps, command = struct_module(step.command), do: {command, :command}) ++
        for(
          step <- steps,
          event <- step.events,
          module = struct_module(event),
          do: {module, :event}
        ) ++
        for(target <- targets, adapter = adapter_of(report, target.name), do: {adapter, :adapter})

    unique =
      listed
      |> Enum.filter(fn {module, _role} -> is_atom(module) and not is_nil(module) end)
      |> Enum.uniq_by(&elem(&1, 0))

    adapters = for target <- targets, adapter = adapter_of(report, target.name), do: adapter
    adapter_files = adapter_files(adapters)
    built = Enum.map(unique, fn {module, role} -> module_entry(module, role, adapter_files) end)

    missing = built |> Enum.flat_map(& &1.missing) |> Enum.uniq()
    redacted = built |> Enum.map(& &1.entry["redactions"]) |> Enum.sum()

    {Enum.map(built, & &1.entry), missing, redacted}
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

  defp projections(%FailureReport{model: model, failure_reason: reason}) do
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
        "file" => file,
        "lines" => text && line_count(text),
        "source" => source,
        "resolution" => resolution(module, file),
        "functions" => functions(module, docs.functions, ranges, text),
        "redactions" => redactions
      })

    %{entry: entry, missing: missing}
  end

  defp read(nil), do: {nil, []}

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> {text, []}
      {:error, _reason} -> {nil, [file]}
    end
  end

  defp source_of(nil, nil, _adapter_files), do: {nil, 0}
  defp source_of(nil, file, _adapter_files), do: {%{"missing" => file}, 0}

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

  defp functions(module, docs, ranges, text) do
    docs
    |> Enum.sort_by(fn {{name, arity}, %{line: line}} -> {line, name, arity} end)
    |> Enum.map(fn {{name, arity}, %{doc: doc, line: line}} ->
      range = Map.get(ranges, {name, arity})
      {from, to} = range(range, line)

      %{
        "id" => source_id(module, name, arity, text != nil and range == nil),
        "name" => to_string(name),
        "arity" => arity,
        "doc" => doc,
        "from" => from,
        "to" => to
      }
    end)
  end

  # A function of a readable file that the file does not define at the top
  # level of its module (a macro injected it) has no lines to cite, so it
  # gets no id. An unreadable file leaves every function its id.
  defp source_id(_module, _name, _arity, true), do: nil
  defp source_id(module, name, arity, false), do: "source:#{inspect(module)}.#{name}/#{arity}"

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

  defp last_line(body) do
    {_ast, last} =
      Macro.prewalk(body, 0, fn
        {_form, meta, _args} = node, last when is_list(meta) ->
          {node, max(last, meta[:line] || 0)}

        node, last ->
          {node, last}
      end)

    last
  end

  defp module_parts([{:__MODULE__, _, _} | rest], parents), do: parents ++ rest
  defp module_parts(parts, parents), do: parents ++ parts
end
