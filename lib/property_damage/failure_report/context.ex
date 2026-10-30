defmodule PropertyDamage.FailureReport.Context do
  @moduledoc false
  # The items of the failure report's "What this checks" section: for the
  # failure at hand, the meaning of its kind and the docs of the model, the
  # check or observation, its projection, the expansion path each target took
  # and the command. A doc that is missing becomes a line that names the
  # fix, so the reader learns what to write and where.
  #
  # `items/3` returns `[%{label:, name:, text:, missing:}]` in print order.
  # `text` holds the printed lines without their indent, joined by a newline,
  # and `missing` is true when the text is a gap line. `lines/1` lays the
  # items out for the terminal and the markdown, and `data/1` shapes them for
  # the JSON format.
  #
  # Docs come from `PropertyDamage.Docs.fetch/1` only. A subject prints its
  # whole doc and a supporting item the text up to the first blank line, both
  # as written. Nothing here raises for a module that is not loaded, a
  # projection without `__compares__/0` or `__checks__/0`, or a failure that
  # names no projection: the item is left out or prints its gap line.

  alias PropertyDamage.{Docs, Expansion, Failure, FailureReport}
  alias PropertyDamage.Failure.Explain

  @type item :: %{
          label: String.t(),
          name: String.t() | nil,
          text: String.t(),
          missing: boolean()
        }

  # A label of this many characters or more stands alone on its line.
  @alone 14

  # The column of the text, and the width left to PropertyDamage's own text.
  @text_column 16
  @wrap_width 80 - @text_column

  # Kinds whose subject is the command that failed.
  @execution_kinds [
    :adapter_error,
    :nemesis_error,
    :stutter_execution_failed,
    :resource_poller_error,
    :retry_from_sync_command,
    :malformed_adapter_return
  ]

  @ordinals ~w(first second third fourth fifth sixth seventh eighth ninth tenth)

  # `focus` is the marked step of the listing (or nil), and `targets` lists
  # each listed target's name with the choices it made, the reference first.
  @doc false
  @spec items(FailureReport.t(), map() | nil, [{String.t(), [map()] | nil}]) :: [item()]
  def items(%FailureReport{} = report, focus, targets) do
    kind = FailureReport.failure_type(report)
    command = command_module(focus)

    [meaning(kind)] ++
      model_items(report) ++
      subject_items(kind, report, command) ++
      path_items(report, targets) ++ last_command_items(kind, command)
  end

  # The lines of the section: items one blank line apart, a label at column 2
  # and the text at column 16.
  @doc false
  @spec lines([item()]) :: [String.t()]
  def lines(items) do
    items |> Enum.map(&item_lines/1) |> Enum.intersperse([""]) |> List.flatten()
  end

  @doc false
  @spec data([item()]) :: [map()]
  def data(items) do
    for item <- items do
      %{
        "label" => item.label,
        "name" => item.name,
        "text" => item.text,
        "missing" => item.missing
      }
    end
  end

  # ==========================================================================
  # Layout
  # ==========================================================================

  defp item_lines(%{label: label, name: name, text: text}) do
    text_lines = String.split(text, "\n")
    alone? = String.length(label) >= @alone
    head = "  " <> String.pad_trailing(label, @alone)

    case {alone?, name} do
      {true, nil} -> ["  " <> label | Enum.map(text_lines, &indent/1)]
      {true, name} -> ["  " <> label, indent(name) | Enum.map(text_lines, &indent/1)]
      {false, nil} -> hang(head, text_lines)
      {false, name} -> [head <> name | Enum.map(text_lines, &indent/1)]
    end
  end

  defp hang(head, [first | rest]), do: [head <> first | Enum.map(rest, &indent/1)]

  # A blank line stays empty rather than ending in spaces.
  defp indent(""), do: ""
  defp indent(line), do: String.duplicate(" ", @text_column) <> line

  # ==========================================================================
  # Meaning and model
  # ==========================================================================

  defp meaning(kind) do
    text =
      try do
        Explain.meaning(kind)
      rescue
        FunctionClauseError -> Explain.meaning(:unknown)
      end

    label = kind |> to_string() |> String.replace("_", " ") |> String.capitalize()
    %{label: label, name: nil, text: wrap(text), missing: false}
  end

  # Wraps at word boundaries so no printed line passes 80 columns.
  defp wrap(text) do
    text
    |> String.split(" ", trim: true)
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | done] ->
        if String.length(line) + 1 + String.length(word) <= @wrap_width,
          do: [line <> " " <> word | done],
          else: [word, line | done]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp model_items(%FailureReport{model: model}) when is_atom(model) and not is_nil(model),
    do: [module_item("Model", model, :paragraph)]

  defp model_items(_report), do: []

  # ==========================================================================
  # Subject items, by kind
  # ==========================================================================

  defp subject_items(
         kind,
         %FailureReport{failure_reason: %Failure{type: type}} = report,
         _command
       )
       when kind in [:check_failed, :poll_timeout] do
    check_items(type) ++ property_items(report)
  end

  defp subject_items(kind, report, _command) when kind in [:check_failed, :poll_timeout],
    do: property_items(report)

  defp subject_items(
         :projection_violation,
         %FailureReport{failure_reason: %Failure{type: %Failure.Check{name: projection}}},
         _command
       )
       when is_atom(projection) and not is_nil(projection),
       do: [module_item("Projection", projection, :full)]

  defp subject_items(
         kind,
         %FailureReport{failure_reason: %Failure{type: %{key: {projection, fun}} = type}},
         _command
       )
       when kind in [:diverged, :did_not_converge] and is_atom(projection) and is_atom(fun) do
    [function_item("Observation", projection, fun, 2, :full)] ++
      relation_items(projection, fun) ++
      also_differed_items(type) ++ [module_item("Projection", projection, :paragraph)]
  end

  defp subject_items(
         :setup_failed,
         %FailureReport{failure_reason: %Failure{type: %Failure.Setup{} = setup}},
         command
       ) do
    case setup do
      %{cause: :adapter_setup} -> []
      %{command: %{__struct__: module}} -> [module_item("Command", module, :full)]
      _other -> command_subject(command)
    end
  end

  defp subject_items(kind, _report, command) when kind in @execution_kinds,
    do: command_subject(command)

  defp subject_items(_kind, _report, _command), do: []

  defp command_subject(nil), do: []
  defp command_subject(module), do: [module_item("Command", module, :full)]

  # The `Command` item that closes the section when the command is not the
  # subject: the command of the marked step.
  defp last_command_items(kind, _command)
       when kind in [:setup_failed, :latency_exceeded] or kind in @execution_kinds,
       do: []

  defp last_command_items(_kind, nil), do: []
  defp last_command_items(_kind, module), do: [module_item("Command", module, :paragraph)]

  defp command_module(%{command: %{__struct__: module}}), do: module
  defp command_module(_focus), do: nil

  # The check function is found by the check's name in the projection's
  # `__checks__/0`. Without it the check item is left out and the projection
  # item stays, so the reader still sees where to look.
  defp check_items(%Failure.Check{projection: projection, name: name})
       when is_atom(projection) and not is_nil(projection) do
    check =
      case function_of_check(projection, name) do
        nil ->
          []

        fun ->
          [function_item("Check", projection, fun, check_arity(projection, fun), :full)]
      end

    check ++ [module_item("Projection", projection, :paragraph)]
  end

  defp check_items(_type), do: []

  defp function_of_check(projection, name) do
    projection
    |> safe_call(:__checks__, [])
    |> List.wrap()
    |> Enum.find_value(fn
      %{name: ^name, function_name: fun} when is_atom(fun) -> fun
      _other -> nil
    end)
  end

  # A check function takes the projection state and one more argument, so
  # arity 2 unless the docs hold the function under another arity.
  defp check_arity(projection, fun) do
    case fetch(projection) do
      {:ok, %{functions: functions}} ->
        arities = for {{^fun, arity}, _doc} <- functions, do: arity
        if 2 in arities or arities == [], do: 2, else: Enum.min(arities)

      :unavailable ->
        2
    end
  end

  # The description of the invariant the failing check validates, as the
  # Failure section prints it.
  defp property_items(%FailureReport{invariant_description: description} = report)
       when is_binary(description) do
    name = FailureReport.invariant_name(report) || FailureReport.check_name(report)
    [item("Property", FailureReport.format_name(name), description, false)]
  end

  defp property_items(_report), do: []

  # The relation prints only when `using:` names a function of a module; a
  # bare atom names a private or local relation and has no item.
  defp relation_items(projection, fun) do
    entry =
      projection
      |> safe_call(:__compares__, [])
      |> List.wrap()
      |> Enum.find(&(is_map(&1) and Map.get(&1, :name) == fun))

    case entry && Map.get(entry, :using) do
      {module, relation} when is_atom(module) and is_atom(relation) ->
        [function_item("Relation", module, relation, 2, :paragraph)]

      {module, relation, args} when is_atom(module) and is_atom(relation) and is_list(args) ->
        [function_item("Relation", module, relation, 2 + length(args), :paragraph)]

      _bare_or_none ->
        []
    end
  end

  defp also_differed_items(%{other_keys: others}) when is_list(others) do
    for %{failure: %Failure{type: %{key: {projection, fun}}}} <- others,
        is_atom(projection) and is_atom(fun),
        do: function_item("Also differed", projection, fun, 2, :paragraph)
  end

  defp also_differed_items(_type), do: []

  # ==========================================================================
  # Path items
  # ==========================================================================

  # One item for each root a listed target ran as a listed expansion entry,
  # the reference first. A root that ran as itself has no item.
  defp path_items(report, targets) do
    for {target, choices} <- targets,
        is_list(choices),
        %{entry: entry} = choice <- choices,
        is_binary(entry),
        do: path_item(report, target, choice)
  end

  defp path_item(report, target, choice) do
    root = Expansion.short(choice.module)
    name = ~s("#{target}" ran #{root} as steps #{Enum.join(leaf_labels(choice), ",")})

    case clean(Map.get(choice, :doc)) do
      "" ->
        item("Path", name, entry_gap(report, choice, root), true)

      doc ->
        item("Path", name, doc, false)
    end
  end

  # The labels the listing prints for the leaves of the root, or the root's
  # own label when it ran as itself under a listed key.
  defp leaf_labels(%{root: root, leaves?: true, commands: commands}),
    do: for(leaf <- 0..(length(commands) - 1)//1, do: "[#{root}.#{leaf}]")

  defp leaf_labels(%{root: root}), do: ["[#{root}]"]

  defp entry_gap(report, choice, root) do
    function =
      case Map.get(choice, :function) do
        nil -> "expansions/0"
        name -> "#{name}/2"
      end

    ~s[(no description: add doc: "..." to the #{ordinal((choice.index || 0) + 1)} entry that ] <>
      "#{inspect(report.model)}.#{function} returns for #{root})"
  end

  defp ordinal(n) when n in 1..10, do: Enum.at(@ordinals, n - 1)

  defp ordinal(n) do
    suffix =
      case {rem(n, 100), rem(n, 10)} do
        {teen, _last} when teen in 11..13 -> "th"
        {_teen, 1} -> "st"
        {_teen, 2} -> "nd"
        {_teen, 3} -> "rd"
        _other -> "th"
      end

    "#{n}#{suffix}"
  end

  # ==========================================================================
  # Docs and gap lines
  # ==========================================================================

  defp item(label, name, text, missing),
    do: %{label: label, name: name, text: text, missing: missing}

  defp module_item(label, module, cut) do
    {text, missing} =
      case fetch(module) do
        :unavailable ->
          {unreadable(module, label), true}

        {:ok, %{moduledoc: doc}} ->
          doc_text(
            doc,
            cut,
            "add @moduledoc to #{inspect(module)}",
            "#{inspect(module)} has @moduledoc false; replace it with a @moduledoc"
          )
      end

    item(label, inspect(module), text, missing)
  end

  defp function_item(label, module, fun, arity, cut) do
    qualified = "#{inspect(module)}.#{fun}/#{arity}"

    {text, missing} =
      case fetch(module) do
        :unavailable ->
          {unreadable(module, label), true}

        {:ok, %{functions: functions}} ->
          doc = functions |> Map.get({fun, arity}, %{}) |> Map.get(:doc)

          doc_text(
            doc,
            cut,
            "add @doc to #{qualified}",
            "#{qualified} has @doc false; replace it with a @doc"
          )
      end

    item(label, qualified, text, missing)
  end

  defp doc_text(doc, cut, none, hidden) do
    case {doc, clean(doc)} do
      {false, _clean} -> {gap(hidden), true}
      {_doc, ""} -> {gap(none), true}
      {_doc, text} -> {cut(text, cut), false}
    end
  end

  defp gap(text), do: "(no description: " <> text <> ")"

  # The `use` line a module declares depends on the role the item gives it.
  defp unreadable(module, label) do
    use_line =
      case label do
        "Model" -> "use PropertyDamage.Model"
        "Command" -> "use PropertyDamage.Command"
        _projection_role -> "use PropertyDamage.Model.Projection"
      end

    gap("PropertyDamage cannot read the docs of #{inspect(module)}; declare it with #{use_line}")
  end

  defp cut(text, :full), do: text
  defp cut(text, :paragraph), do: text |> then(&Regex.split(~r/\n[ \t]*\n/, &1, parts: 2)) |> hd()

  # The doc without the blank lines at either end; "" for a doc with no text.
  defp clean(doc) when is_binary(doc) do
    doc
    |> String.split("\n")
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp clean(_doc), do: ""

  defp blank?(line), do: String.trim(line) == ""

  defp fetch(module) do
    Docs.fetch(module)
  rescue
    _error -> :unavailable
  end

  # Calls a function of a user module that may be missing or may raise.
  defp safe_call(module, fun, default) do
    if Code.ensure_loaded?(module) and function_exported?(module, fun, 0) do
      apply(module, fun, [])
    else
      default
    end
  rescue
    _error -> default
  end
end
