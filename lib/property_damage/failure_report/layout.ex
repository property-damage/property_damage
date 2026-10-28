defmodule PropertyDamage.FailureReport.Layout do
  @moduledoc false
  # The failure report's layout as plain data (DR-055, DR-056): the banner,
  # the seed and the sections in order, each a heading and a list of lines.
  # `build/1` reads a report once; `PropertyDamage.FailureReport.Render`
  # turns the result into terminal text, with or without color, and into
  # markdown. Nothing here holds ANSI codes or markdown, so a new kind of line
  # (a log line under a step) or a new section is added in one place, and
  # both formats print it.
  #
  # A line is one of:
  #
  #   * `:blank`
  #   * `{:field, label, parts}` - a labeled field of the Failure section;
  #     the renderer lines up the values of one section in one column
  #   * `{:header, text}` - the header of a listing (`Reference: target "a"`)
  #   * `{:step, step}` - a command of a listing, `%{depth:, label:, root:,
  #     command:, note:, outcome:}`; `outcome` is nil, or the word printed after
  #     `◄──` on the failing step, which also carries `►`; `root` is the index
  #     of the root it belongs to, nil for a setup or teardown command
  #   * `{:event, %{offset_ms:, source:, event:}}` - an event under its step
  #   * `{:log, %{offset_ms:, tags:, message:, file:, line:, attempt:}}` - a log
  #     line (DR-054) under its step or under an adapter note; `message` is
  #     `{:text, string}` or `{:value, term}`, a function message already
  #     called. A tag filter (`PropertyDamage.Log.Filter`) removes the lines it
  #     hides before this point, so no renderer sees one
  #   * `{:gap, %{attempts:, lines:}}` - the attempts the retry cap dropped from
  #     a step (DR-054 decision 13), in their place among the step's log lines
  #   * `{:note, text}` - a line of a listing that is not a step
  #   * `{:projection, name, last_applied}` - a projection's header line
  #   * `{:attribute, marker, key, value}` - a projection attribute, `marker`
  #     `:same`, `:minus` or `:plus`; `key` is nil for a state that is not a map
  #   * `{:comment, text}`, `{:code, text}`, `{:text, text}` - lines of the
  #     Reproduction section
  #
  # `parts` is a list of strings and `{:value, term}`; the renderer inspects
  # each value, so it alone decides on syntax colors.

  alias PropertyDamage.Log.{Filter, Gap, Line}

  alias PropertyDamage.{
    ComparisonMismatch,
    Failure,
    FailureReport,
    LatencyMetrics,
    RunTrace,
    Sequence,
    Target
  }

  alias PropertyDamage.RunTrace.Step
  alias PropertyDamage.Sequence.Position

  defmodule Section do
    @moduledoc false
    # One `## ` section: its heading, the language of the markdown fence its
    # body is printed in (nil for none), and its lines.
    defstruct [:heading, :fence, lines: []]
  end

  # `logs` is what the `:json` format carries of the log lines (see
  # `logs_data/4`), built from the same lines the sections hold.
  defstruct [:banner, :seed, :logs, sections: []]

  @type t :: %__MODULE__{
          banner: :bug_detected | :test_code_error,
          seed: integer() | nil,
          sections: [%Section{}],
          logs: map() | nil
        }

  @default_converge_within 5_000

  # The notes that head the adapter's setup/1 and teardown/1 lines.
  @adapter_setup_note "adapter setup/1"
  @adapter_teardown_note "adapter teardown/1"

  # `opts` holds the `log:` filter a caller gives for this one formatting
  # (`PropertyDamage.Log.Filter.resolve/2` decides what applies). A filter
  # hides whole log lines here and nowhere else: every origin below counts
  # from all of a target's lines, so a hidden line moves no other offset.
  @doc false
  @spec build(FailureReport.t(), keyword()) :: t()
  def build(%FailureReport{} = report, opts \\ []) do
    listing = listing_data(report, opts)
    %{filter: filter, unknown: unknown, variant: variant, focus: focus, setup: setup} = listing

    sections =
      [
        failure_section(report, focus, filter, unknown),
        setup && setup.section,
        listing.section,
        projections_section(report, variant, focus),
        reproduction_section(report)
      ]
      |> Enum.reject(&is_nil/1)

    %__MODULE__{
      banner: banner(report),
      seed: report.seed,
      sections: sections,
      logs: logs_of(listing)
    }
  end

  # The `logs` map of `build/2` (what the `:json` format carries) without
  # the Failure, Projections and Reproduction sections, so a report whose
  # messages cannot be built still yields its log lines. `build/2` reads the
  # same data, so the two cannot drift.
  @doc false
  @spec logs(FailureReport.t(), keyword()) :: map()
  def logs(%FailureReport{} = report, opts \\ []), do: report |> listing_data(opts) |> logs_of()

  # The data of the listing and the log lines: the filter, the side of the
  # failing target, the failing step, the Setup lines and the Minimal
  # Reproduction section with the log lines of each target it lists.
  defp listing_data(report, opts) do
    filter = Filter.resolve(report.log_filter, opts)
    unknown = Filter.unknown(filter, known_tags(report))

    variant =
      side(report, report.trace, variant_name(report), FailureReport.steps(report), filter)

    focus = focus(report, variant.items)
    {section, targets} = reproduction_listing(report, variant, focus)

    %{
      filter: filter,
      unknown: unknown,
      variant: variant,
      focus: focus,
      section: section,
      targets: targets,
      setup: setup_section(report, filter)
    }
  end

  defp logs_of(%{filter: filter, unknown: unknown, targets: targets, setup: setup}) do
    %{
      filter: filter,
      unknown: unknown,
      setup: (setup && setup.lines) || [],
      target: targets.target,
      reference: targets.reference
    }
  end

  # Every tag of every line the report holds, before any filter.
  defp known_tags(report) do
    traces = Enum.reject([report.trace, report.reference_trace], &is_nil/1)
    traced = for trace <- traces, lines <- Map.values(Map.get(trace, :logs) || %{}), do: lines

    MapSet.new(Filter.tag_names((report.setup_log || []) ++ List.flatten(traced)))
  end

  defp banner(%FailureReport{error_origin: :test_code_error}), do: :test_code_error
  defp banner(_report), do: :bug_detected

  # ==========================================================================
  # Listing items: every command a target ran, with its label and events
  # ==========================================================================

  # A target's side of the run: the items of its listing (setup commands,
  # roots with their leaves, teardown commands), the log lines of its
  # adapter's setup/1 and teardown/1, the entries tied to no command, and the
  # start its offsets count from: the earliest timestamp among its events and
  # its log lines, so no line prints a negative offset.
  defp side(report, trace, name, steps, filter) do
    plan = trace && trace.plan
    log = (trace && trace.event_log) || []
    logs = (trace && Map.get(trace, :logs)) || %{}

    items =
      phase_items(:setup, report.setup_commands, log, logs) ++
        root_items(plan, steps, choices(trace, name)) ++
        phase_items(:teardown, report.teardown_commands, log, logs)

    timestamps =
      Enum.map(log, & &1.timestamp) ++
        for {_key, lines} <- logs, %Line{} = line <- lines, do: line.timestamp

    %{
      trace: trace,
      items: items,
      adapter_setup: Map.get(logs, :adapter_setup, []),
      adapter_teardown: Map.get(logs, :adapter_teardown, []),
      untied: if(trace, do: RunTrace.async_entries(trace), else: []),
      missing?: false,
      filter: filter,
      start: Enum.min(timestamps, fn -> nil end)
    }
  end

  defp phase_items(phase, commands, log, logs) do
    for {command, offset} <- Enum.with_index(commands) do
      position = %Position{section: phase, offset: offset}

      %{
        kind: phase,
        position: position,
        label: Position.label(position),
        command: command,
        entries: Enum.filter(log, &(&1.phase == phase and &1.command_index == offset)),
        logs: Map.get(logs, position, []),
        root: nil,
        failed?: false,
        note: nil
      }
    end
  end

  # Walks the plan's roots beside the steps: a root that ran as itself is
  # its step; a root that ran as leaves is a line of its own, which names
  # the entry, followed by one item per leaf.
  defp root_items(nil, _steps, _choices), do: []

  defp root_items(%Sequence{} = plan, steps, choices),
    do: plan |> Sequence.indexed() |> walk_roots(steps, choices)

  defp walk_roots([], _steps, _choices), do: []

  defp walk_roots([{position, index, command} | rest], steps, choices) do
    case steps do
      [%Step{position: ^position} = step | more] ->
        item = step_item(:root, step, index)
        note = join_notes(entry_note(choices, index), item.note)
        [%{item | note: note} | walk_roots(rest, more, choices)]

      [%Step{position: %Position{section: {:leaf, id}}} | _] ->
        {leaves, more} = Enum.split_while(steps, &leaf_of?(&1, id))
        root = root_item(position, index, command, entry_note(choices, index))
        [root | Enum.map(leaves, &step_item(:leaf, &1, index))] ++ walk_roots(rest, more, choices)

      _other ->
        [root_item(position, index, command, nil) | walk_roots(rest, steps, choices)]
    end
  end

  defp leaf_of?(%Step{position: %Position{section: {:leaf, id}}}, id), do: true
  defp leaf_of?(_step, _id), do: false

  defp step_item(kind, %Step{} = step, root) do
    %{
      kind: kind,
      position: step.position,
      label: Position.label(step.position, root),
      command: step.command,
      entries: step.entries,
      logs: step.logs,
      root: root,
      failed?: step.failed?,
      note: comment(step.label)
    }
  end

  defp root_item(position, index, command, note) do
    %{
      kind: :root,
      position: position,
      label: Position.label(position, index),
      command: command,
      entries: [],
      logs: [],
      root: index,
      failed?: false,
      note: note
    }
  end

  defp comment(label) when is_binary(label), do: "# " <> label
  defp comment(_label), do: nil

  defp choices(%RunTrace{expansion: expansion}, name) when is_map(expansion),
    do: Map.get(expansion, name)

  defp choices(_trace, _name), do: nil

  # The expansion entry a root ran as, as the root line names it: the entry
  # of its leaves, or itself in place of an entry.
  defp entry_note(choices, index) when is_list(choices) do
    case Enum.find(choices, &(&1.root == index)) do
      %{entry: entry} when is_binary(entry) -> "as " <> entry
      %{entry: :identity} -> "as itself (identity, by shrinking)"
      %{entry: :forced} -> "as itself (identity, forced)"
      _other -> nil
    end
  end

  defp entry_note(_choices, _index), do: nil

  defp join_notes(nil, note), do: note
  defp join_notes(note, nil), do: note
  defp join_notes(first, second), do: first <> "  " <> second

  # ==========================================================================
  # The failing step
  # ==========================================================================

  # The step the failure is reported at (DR-055 decision 5): for a comparison,
  # the root at the failing boundary, also when the target ran it as leaves;
  # for a setup command's failure, that command; otherwise the step the
  # failure was localized to. Nil for a failure no step is tied to.
  defp focus(%FailureReport{kind: kind, failed_at_index: root} = report, items)
       when kind in [:diverged, :did_not_converge] and is_integer(root) do
    match = &(&1.kind == :root and &1.root == root)
    found(items, match) || %{label: "[#{root}]", command: compared_command(report), match: match}
  end

  defp focus(%FailureReport{failure_reason: %Failure{type: %Failure.Setup{} = setup}}, items)
       when setup.cause != :adapter_setup and is_integer(setup.setup_index) do
    match = &(&1.kind == :setup and &1.position.offset == setup.setup_index)

    found(items, match) ||
      %{
        label: Position.label(Position.setup(setup.setup_index)),
        command: setup.command,
        match: match
      }
  end

  defp focus(_report, items), do: found(items, & &1.failed?)

  defp found(items, match) do
    case Enum.find(items, match) do
      nil -> nil
      item -> %{label: item.label, command: item.command, match: match}
    end
  end

  defp compared_command(%FailureReport{failure_reason: %Failure{type: %{command: command}}}),
    do: command

  defp compared_command(_report), do: nil

  defp outcome(:diverged), do: "diverged"
  defp outcome(:did_not_converge), do: "did not converge"
  defp outcome(_kind), do: "failed"

  # ==========================================================================
  # Failure
  # ==========================================================================

  defp failure_section(report, focus, filter, unknown) do
    fields =
      [{"Failure", [kind_text(report.failure_reason)]}] ++
        name_fields(report) ++
        target_fields(report) ++
        at_fields(focus) ++
        detail_fields(report) ++
        origin_fields(report) ++
        also_differed_fields(report) ++
        other_failure_fields(report) ++
        shrink_fields(report) ++
        log_filter_fields(filter, unknown)

    %Section{
      heading: "Failure",
      lines: Enum.map(fields, fn {label, parts} -> {:field, label, parts} end)
    }
  end

  defp kind_text(%Failure{} = failure),
    do: failure |> Failure.kind() |> to_string() |> String.replace("_", " ")

  defp kind_text(_failure_reason), do: "unknown"

  defp name_fields(%FailureReport{failure_reason: %Failure{type: %type{key: key}}})
       when type in [Failure.Divergence, Failure.Convergence],
       do: [{"Observation", [FailureReport.format_name(key)]}]

  defp name_fields(%FailureReport{failure_reason: %Failure{type: %Failure.Latency{}}}), do: []

  # The invariant the failing check validates (DR-026), when its name says
  # more than the check's, then the check.
  defp name_fields(report) do
    check = report |> FailureReport.check_name() |> check_text()

    invariant =
      case FailureReport.invariant_name(report) do
        nil ->
          []

        name ->
          invariant_field(to_string(name), check) ++ property_field(report.invariant_description)
      end

    if check, do: invariant ++ [{"Check", [check]}], else: invariant
  end

  defp check_text(nil), do: nil
  defp check_text(name), do: FailureReport.format_name(name)

  defp invariant_field(check, check), do: []
  defp invariant_field(name, _check), do: [{"Invariant", [name]}]

  defp property_field(nil), do: []
  defp property_field(description), do: [{"Property", [description]}]

  # The target a failure happened in, when the run had several and the
  # failure is not a comparison, which names both sides itself.
  defp target_fields(%FailureReport{kind: kind}) when kind in [:diverged, :did_not_converge],
    do: []

  defp target_fields(%FailureReport{targets: [_, _ | _], variant: %{name: name}}),
    do: [{"Target", [inspect(name)]}]

  defp target_fields(_report), do: []

  defp at_fields(nil), do: []

  defp at_fields(%{label: label, command: nil}), do: [{"At", [label]}]

  defp at_fields(%{label: label, command: command}),
    do: [{"At", [label, " ", {:value, command}]}]

  defp detail_fields(%FailureReport{failure_reason: %Failure{type: type} = failure} = report) do
    case type do
      %Failure.Divergence{} -> divergence_fields(report, type)
      %Failure.Convergence{} -> convergence_fields(report, type)
      %Failure.Latency{} -> latency_fields(type)
      %Failure.Setup{} -> setup_fields(report, type)
      %Failure.Check{kind: :idempotency_violation} -> idempotency_fields(report)
      %Failure.Check{kind: :poll_timeout} -> poll_timeout_fields(report)
      _other -> message_fields(report, failure)
    end
  end

  defp detail_fields(%FailureReport{failure_reason: reason}),
    do: [{"Message", [{:value, reason}]}]

  defp message_fields(report, failure) do
    case FailureReport.failure_message(report) do
      nil -> [{"Message", [{:value, failure}]}]
      message -> [{"Message", [String.trim_trailing(message)]}]
    end
  end

  defp divergence_fields(report, divergence) do
    [
      {"Reference", side_value(reference_name(report), divergence.reference_value)},
      {"Variant", side_value(variant_name(report), divergence.variant_value)},
      {"Compared",
       [
         "using #{relation_text(divergence.using)}, " <>
           waited_text("still differing", divergence, report)
       ]}
    ] ++ mismatch_fields(divergence.mismatch)
  end

  defp convergence_fields(report, convergence) do
    [
      {"Variant",
       [inspect(variant_name(report)), "  still pending: ", {:value, convergence.reason}]},
      {"Compared",
       [
         "using #{relation_text(written_relation(convergence.key))}, " <>
           waited_text("still pending", convergence, report)
       ]}
    ]
  end

  defp side_value(name, value), do: [inspect(name), "  ", {:value, value}]

  defp relation_text(nil), do: "=="
  defp relation_text(using), do: inspect(using)

  # The `using:` a convergence's observation declares; a failure to converge
  # records none, so it is read from the projection.
  defp written_relation({projection, name}) when is_atom(projection) do
    if Code.ensure_loaded?(projection) and function_exported?(projection, :__compares__, 0) do
      Enum.find_value(projection.__compares__(), &(&1.name == name and &1.using))
    end
  end

  defp written_relation(_key), do: nil

  defp waited_text(state, failure, report) do
    bound = Map.get(failure, :within_ms) || converge_within(report)

    case Map.get(failure, :waited_ms) do
      nil -> "#{state} at the bound (#{bound} ms)"
      waited -> "#{state} after #{waited} ms (bound #{bound} ms)"
    end
  end

  defp converge_within(%FailureReport{compare: compare}) when is_list(compare),
    do: Keyword.get(compare, :converge_within, @default_converge_within)

  defp converge_within(_report), do: @default_converge_within

  # Mismatch prints only the reason a relation failed with; a relation that
  # answered false or nil left only the two values, printed above it.
  defp mismatch_fields(nil), do: []
  defp mismatch_fields(%ComparisonMismatch{message: nil}), do: []
  defp mismatch_fields(%ComparisonMismatch{message: message}), do: [{"Mismatch", [message]}]

  defp mismatch_fields(exception) when is_exception(exception),
    do: [{"Mismatch", [Exception.message(exception)]}]

  defp mismatch_fields(other), do: [{"Mismatch", [{:value, other}]}]

  defp latency_fields(latency) do
    [
      {"Statistic", [to_string(latency.statistic)]},
      {"Bound", [to_string(latency.bound)]},
      {"Limit", [{:value, latency.limit}]},
      {"Measured", [{:value, latency.value}]},
      {"Verdict", [LatencyMetrics.describe(latency)]}
    ]
  end

  defp setup_fields(report, setup) do
    cause =
      case setup.cause do
        :unresolved_placeholder -> "unresolved_placeholder, field #{inspect(setup.field)}"
        cause -> to_string(cause)
      end

    [{"Cause", [cause]}, {"Message", [FailureReport.failure_message(report)]}]
  end

  defp idempotency_fields(report) do
    case FailureReport.idempotency_violation(report) do
      %{attempts: attempts, mismatch: mismatch} ->
        attempt_fields =
          for attempt <- attempts do
            which = if attempt.is_retry, do: "retry: ", else: "original: "
            {"Attempt #{attempt.attempt}", [which, {:value, attempt.events}]}
          end

        attempt_fields ++ [{"Difference", [mismatch_text(mismatch)]}]

      _other ->
        [{"Message", [FailureReport.failure_message(report)]}]
    end
  end

  defp mismatch_text(mismatch) when is_exception(mismatch), do: Exception.message(mismatch)
  defp mismatch_text(other), do: inspect(other, pretty: true)

  defp poll_timeout_fields(report) do
    case FailureReport.poll_timeout_info(report) do
      %{} = info ->
        [
          {"Waited", ["#{info.elapsed_ms} ms, #{info.poll_count} polls"]},
          {"Trigger", [{:value, info.triggered_by.event}]},
          {"Predicate", [info.predicate_source || "unknown"]},
          {"Final state", [{:value, info.final_state}]}
        ]

      nil ->
        [{"Message", [FailureReport.failure_message(report)]}]
    end
  end

  # A failure in the test code says what went wrong and how to fix it.
  defp origin_fields(%FailureReport{
         error_origin: :test_code_error,
         error_origin_details: details
       })
       when is_map(details) do
    evidence = if is_map(details[:evidence]), do: details.evidence, else: %{}

    [{"What went wrong", [to_string(details[:reason]) <> confidence_text(details[:confidence])]}] ++
      hint_fields(evidence)
  end

  defp origin_fields(_report), do: []

  defp confidence_text(:medium), do: " (medium confidence)"
  defp confidence_text(:low), do: " (low confidence: it could be a bug in the system)"
  defp confidence_text(_confidence), do: ""

  defp hint_fields(%{hint: hint}) when is_binary(hint), do: [{"Hint", [hint]}]

  defp hint_fields(%{stacktrace_hint: hint}) when is_binary(hint),
    do: [{"Location", [hint]}]

  defp hint_fields(_evidence), do: []

  # Every further observation that disagreed at the same boundary.
  defp also_differed_fields(
         %FailureReport{failure_reason: %Failure{type: %{other_keys: others}}} = report
       )
       when is_list(others) do
    for other <- others, do: {"Also differed", other_key_parts(report, other)}
  end

  defp also_differed_fields(_report), do: []

  defp other_key_parts(report, %{variant: variant, failure: %Failure{type: type}}) do
    name = FailureReport.format_name(Map.get(type, :key))

    case type do
      %Failure.Divergence{} ->
        [name, "  "] ++
          side_value(reference_name(report), type.reference_value) ++
          ["  "] ++ side_value(variant.name, type.variant_value)

      %Failure.Convergence{} ->
        [name, "  ", inspect(variant.name), " still pending: ", {:value, type.reason}]
    end
  end

  # Every other failure of the run, and under it the further observations
  # that disagreed at its boundary.
  defp other_failure_fields(%FailureReport{other_failures: others} = report)
       when is_list(others) do
    for other <- others do
      nested =
        case other.failure do
          %Failure{type: %{other_keys: [_ | _] = keys}} ->
            Enum.flat_map(keys, &["\nalso differed: " | other_key_parts(report, &1)])

          _other ->
            []
        end

      {"Other failure", other_failure_parts(report, other) ++ nested}
    end
  end

  defp other_failure_fields(_report), do: []

  # Kind, name, target and root once. A comparison failure then prints its
  # values as an `Also differed` line does, and a relation's own reason as
  # `Mismatch` would; any other failure its message.
  defp other_failure_parts(report, %{variant: variant, failure: failure} = other) do
    name =
      case Failure.name(failure) do
        nil -> ""
        name -> " " <> FailureReport.format_name(name)
      end

    head =
      "#{kind_text(failure)}#{name} in target #{inspect(variant.name)} (index #{variant.index})" <>
        root_text(other.root)

    case failure do
      %Failure{type: %Failure.Divergence{} = divergence} ->
        [head, "  "] ++
          side_value(reference_name(report), divergence.reference_value) ++
          ["  "] ++
          side_value(variant.name, divergence.variant_value) ++
          nested_mismatch(divergence.mismatch)

      %Failure{type: %Failure.Convergence{reason: reason}} ->
        [head, "  ", inspect(variant.name), " still pending: ", {:value, reason}]

      _other ->
        [head <> message_text(failure)]
    end
  end

  defp root_text(nil), do: ""
  defp root_text(root), do: " at root #{root}"

  defp nested_mismatch(mismatch) do
    case mismatch_fields(mismatch) do
      [{"Mismatch", parts}] -> ["\nmismatch: " | parts]
      [] -> []
    end
  end

  defp message_text(failure) do
    case FailureReport.failure_message(failure) do
      nil -> ""
      message -> ": " <> String.trim_trailing(message)
    end
  end

  defp shrink_fields(%FailureReport{shrink_stop: :max_iterations}),
    do: [{"Shrink", [shrink_text("iteration")]}]

  defp shrink_fields(%FailureReport{shrink_stop: :max_time}),
    do: [{"Shrink", [shrink_text("time")]}]

  defp shrink_fields(_report), do: []

  # The tag filter the report applied and where it came from, then the listed
  # tags no line carries: two fields at the end of the Failure section, and
  # none without a filter (DR-054 decision 11).
  defp log_filter_fields(nil, _unknown), do: []

  defp log_filter_fields(filter, unknown) do
    [{"Log filter", [Filter.describe(filter)]}] ++
      if unknown == [], do: [], else: [{"Log warning", [Filter.describe_unknown(unknown)]}]
  end

  defp shrink_text(budget),
    do: "stopped at its #{budget} budget, so the reproduction may not be minimal"

  # ==========================================================================
  # Setup
  # ==========================================================================

  # The lines a test captured before the run (DR-054 decision 8), printed once
  # whatever the number of targets, right after Failure. They are shared by
  # every run, so they belong to no target: their offsets count from the
  # earliest of them and they never enter a target's offset origin.
  defp setup_section(%FailureReport{setup_log: [_ | _] = lines}, filter) do
    start = lines |> Enum.map(& &1.timestamp) |> Enum.min()

    case entry_lines([], lines, start, filter) do
      [] ->
        nil

      shown ->
        %{
          lines: shown,
          section: %Section{
            heading: "Setup",
            lines: [{:note, "Logged before the run, shared by every run"} | shown]
          }
        }
    end
  end

  defp setup_section(_report, _filter), do: nil

  # ==========================================================================
  # Minimal Reproduction
  # ==========================================================================

  # The section, and the log lines each target's listing shows, which the
  # `:json` format carries: `%{target:, reference:}`, the reference nil for a
  # report that lists one target.
  defp reproduction_listing(report, variant, focus) do
    {lines, targets} =
      if report.kind in [:diverged, :did_not_converge] do
        reference = reference_side(report, variant.filter)
        reference_lines = listing(reference, focus, report.kind)
        variant_lines = listing(variant, focus, report.kind)

        lines =
          [{:header, ~s(Reference: target "#{reference_name(report)}")}] ++
            reference_lines ++
            [:blank, {:header, ~s(Variant: target "#{variant_name(report)}")}] ++
            variant_lines

        {lines,
         %{
           target: target_logs(variant_name(report), variant_lines),
           reference: target_logs(reference_name(report), reference_lines)
         }}
      else
        lines = listing(variant, focus, report.kind)
        {lines, %{target: target_logs(variant_name(report), lines), reference: nil}}
      end

    {%Section{heading: "Minimal Reproduction (#{roots_text(report)})", lines: lines}, targets}
  end

  # The log lines of one target's listing, read from the lines the listing
  # printed: the adapter's setup/1 and teardown/1 lines, and each step's lines
  # and gaps in report order. Nothing is filtered here; the listing already was.
  defp target_logs(name, lines) do
    {adapter_setup, steps, adapter_teardown, _where} =
      Enum.reduce(lines, {[], [], [], :none}, &collect_logs/2)

    %{
      name: name,
      adapter_setup: Enum.reverse(adapter_setup),
      adapter_teardown: Enum.reverse(adapter_teardown),
      steps: steps |> Enum.map(&%{&1 | lines: Enum.reverse(&1.lines)}) |> Enum.reverse()
    }
  end

  defp collect_logs({:step, step}, {setup, steps, teardown, _where}),
    do: {setup, [%{label: step.label, root: step.root, lines: []} | steps], teardown, :step}

  defp collect_logs({:note, @adapter_setup_note}, {setup, steps, teardown, _where}),
    do: {setup, steps, teardown, :setup}

  defp collect_logs({:note, @adapter_teardown_note}, {setup, steps, teardown, _where}),
    do: {setup, steps, teardown, :teardown}

  defp collect_logs({kind, _line} = entry, {setup, steps, teardown, where})
       when kind in [:log, :gap] do
    case where do
      :setup -> {[entry | setup], steps, teardown, where}
      :teardown -> {setup, steps, [entry | teardown], where}
      :step -> {setup, add_to_first(steps, entry), teardown, where}
    end
  end

  defp collect_logs({:event, _event}, acc), do: acc
  defp collect_logs(_other, {setup, steps, teardown, _where}), do: {setup, steps, teardown, :none}

  defp add_to_first([step | rest], entry), do: [%{step | lines: [entry | step.lines]} | rest]

  # The reference's side; a report saved before it kept the reference's
  # trace lists the roots alone.
  defp reference_side(%FailureReport{reference_trace: %RunTrace{} = trace} = report, filter),
    do: side(report, trace, reference_name(report), FailureReport.reference_steps(report), filter)

  defp reference_side(%FailureReport{} = report, filter) do
    plan = FailureReport.shrunk_sequence(report)
    steps = if plan, do: RunTrace.build_steps(plan, [], %{}, nil), else: []
    trace = %RunTrace{plan: plan}

    %{side(report, trace, reference_name(report), steps, filter) | untied: [], missing?: true}
  end

  # The adapter's setup/1 lines lead the listing and its teardown/1 lines end
  # it, each under a note and only when there are some (DR-054).
  defp listing(%{items: []} = side, _focus, _kind) do
    adapter_lines(side.adapter_setup, @adapter_setup_note, side) ++
      [{:note, "(no command ran)"}] ++
      adapter_lines(side.adapter_teardown, @adapter_teardown_note, side) ++
      untied_lines(side)
  end

  defp listing(side, focus, kind) do
    steps =
      Enum.flat_map(side.items, fn item ->
        [
          {:step, step_line(item, focus, kind)}
          | entry_lines(item.entries, item.logs, side.start, side.filter)
        ]
      end)

    missing =
      if side.missing?,
        do: [{:note, "(this report holds no events of the reference)"}],
        else: []

    adapter_lines(side.adapter_setup, @adapter_setup_note, side) ++
      steps ++
      adapter_lines(side.adapter_teardown, @adapter_teardown_note, side) ++
      missing ++ untied_lines(side)
  end

  # The note prints only when the filter leaves a line under it.
  defp adapter_lines(lines, note, side) do
    case entry_lines([], lines, side.start, side.filter) do
      [] -> []
      shown -> [{:note, note} | shown]
    end
  end

  defp step_line(item, focus, kind) do
    %{
      depth: if(item.kind == :leaf, do: 1, else: 0),
      label: item.label,
      root: item.root,
      command: item.command,
      note: item.note,
      outcome: if(focus && focus.match.(item), do: outcome(kind))
    }
  end

  # A step's events and log lines in timestamp order, stable; on an equal
  # millisecond a line prints before an event, because a line is written
  # while the command runs and its events are recorded when it returns.
  defp entry_lines(entries, lines, start, filter) do
    ((lines |> Enum.filter(&Filter.shown?(&1, filter)) |> Enum.map(&{:log, &1})) ++
       Enum.map(entries, &{:event, &1}))
    |> Enum.sort_by(fn
      {:log, line} -> {line.timestamp, 0}
      {:event, entry} -> {entry.timestamp, 1}
    end)
    |> Enum.map(fn
      {:log, %Gap{} = gap} -> {:gap, %{attempts: gap.attempts, lines: gap.lines}}
      {:log, line} -> log_line(line, start)
      {:event, entry} -> event_line(entry, start)
    end)
  end

  defp event_lines(entries, start), do: entry_lines(entries, [], start, nil)

  defp event_line(entry, start) do
    {:event,
     %{
       offset_ms: entry.timestamp - (start || entry.timestamp),
       source: entry.source,
       event: entry.event
     }}
  end

  defp log_line(line, start) do
    {:log,
     %{
       offset_ms: line.timestamp - (start || line.timestamp),
       tags: line.tags,
       message: log_message(line.message),
       file: line.file,
       line: line.line,
       attempt: line.attempt
     }}
  end

  # A string prints as written and any other value through the renderer's
  # inspect; a binary that is not valid UTF-8 counts as a value, so the
  # report stays valid UTF-8. A function is called now, when the report is formatted, and its
  # result is shown by those two rules; one that raises, throws or exits
  # prints a marker instead (DR-054 decision 3).
  defp log_message(message) when is_function(message, 0) do
    message.() |> shown()
  rescue
    exception -> {:text, "(log line raised: #{Exception.message(exception)})"}
  catch
    kind, reason -> {:text, "(log line raised: #{Exception.format_banner(kind, reason)})"}
  end

  defp log_message(message), do: shown(message)

  defp shown(message) when is_binary(message) do
    if String.valid?(message), do: {:text, message}, else: {:value, message}
  end

  defp shown(message), do: {:value, message}

  defp untied_lines(%{untied: []}), do: []

  defp untied_lines(side),
    do: [:blank, {:note, "Not tied to a command"} | event_lines(side.untied, side.start)]

  defp roots_text(report) do
    case FailureReport.shrunk_sequence(report) do
      %Sequence{} = sequence -> count_text(Sequence.command_count(sequence))
      nil -> count_text(0)
    end
  end

  defp count_text(1), do: "1 root"
  defp count_text(n), do: "#{n} roots"

  # ==========================================================================
  # Projections
  # ==========================================================================

  defp projections_section(report, variant, focus) do
    {minus, plus, legend_parts} = compared_states(report)

    if state?(minus) or state?(plus) do
      legend = legend(legend_parts, minus, plus)
      at = if focus, do: focus.label, else: "the failure"
      applied = last_applied(variant, focus)

      lines =
        minus
        |> modules(plus)
        |> Enum.map(fn module ->
          [
            {:projection, inspect(module), applied}
            | attributes(Map.get(minus || %{}, module), Map.get(plus || %{}, module))
          ]
        end)
        |> Enum.intersperse([:blank])
        |> Enum.concat()

      %Section{heading: "Projections at #{at}   (#{legend})", fence: "diff", lines: lines}
    end
  end

  # Both sides of the diff come from one source: for a comparison, the
  # reference's and the variant's states cut at the failing boundary (DR-040),
  # so nothing the variant folded after it shows; otherwise the state before
  # and after the failing step.
  defp compared_states(%FailureReport{kind: kind} = report)
       when kind in [:diverged, :did_not_converge] do
    legend =
      {~s(- reference "#{reference_name(report)}"), ~s(+ variant "#{variant_name(report)}")}

    {report.reference_state_at_failure, variant_cut(report), legend}
  end

  defp compared_states(report),
    do: {report.state_before_failure, report.state_at_failure, {"- before", "+ after"}}

  # The legend names a side only when that side has state.
  defp legend({minus_text, plus_text}, minus, plus) do
    [{minus, minus_text}, {plus, plus_text}]
    |> Enum.filter(fn {state, _text} -> state?(state) end)
    |> Enum.map_join(", ", fn {_state, text} -> text end)
  end

  defp variant_cut(%FailureReport{trace: %RunTrace{} = trace, failed_at_index: root})
       when is_integer(root),
       do: RunTrace.state_at(trace, Position.prefix(root))

  defp variant_cut(report), do: report.state_at_failure

  defp state?(state), do: is_map(state) and map_size(state) > 0

  defp modules(minus, plus) do
    (Map.keys(minus || %{}) ++ Map.keys(plus || %{}))
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
  end

  defp attributes(minus, plus) do
    case {as_map(minus), as_map(plus)} do
      {{:map, m}, {:map, p}} ->
        (Map.keys(m) ++ Map.keys(p))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(&attribute(&1, fetch(m, &1), fetch(p, &1)))

      _other ->
        attribute(nil, present(minus), present(plus))
    end
  end

  defp as_map(nil), do: {:map, %{}}
  defp as_map(%_{} = struct), do: {:map, Map.from_struct(struct)}
  defp as_map(map) when is_map(map), do: {:map, map}
  defp as_map(other), do: {:other, other}

  defp fetch(map, key),
    do: if(Map.has_key?(map, key), do: {:ok, Map.fetch!(map, key)}, else: :none)

  defp present(nil), do: :none
  defp present(value), do: {:ok, value}

  defp attribute(key, {:ok, same}, {:ok, same}), do: [{:attribute, :same, key, same}]

  defp attribute(key, minus, plus) do
    for {marker, {:ok, value}} <- [minus: minus, plus: plus],
        do: {:attribute, marker, key, value}
  end

  # The event the projections folded last up to the failing step, on the
  # side printed with `+`: the latest fold at or before the step's own folds
  # (DR-040), or, in a trace without fold ordinals, the step's last event.
  defp last_applied(%{trace: nil}, _focus), do: nil

  defp last_applied(side, focus) do
    block = focus_block(side.items, focus)
    cutoff = cutoff(side.trace, block)

    entry =
      if cutoff do
        side.trace.event_log
        |> Enum.filter(&(&1.fold_index != nil and &1.fold_index <= cutoff))
        |> Enum.max_by(& &1.fold_index, fn -> nil end)
      else
        side.items
        |> through(block)
        |> Enum.flat_map(&Enum.sort_by(&1.entries, fn entry -> entry.timestamp end))
        |> List.last()
      end

    entry && short_name(entry.event)
  end

  # The failing step's item and, for a root that ran as leaves, its leaves.
  defp focus_block(items, nil), do: items

  defp focus_block(items, focus) do
    case Enum.find(items, focus.match) do
      nil ->
        []

      %{kind: :root, root: root} = item ->
        [item | Enum.filter(items, &(&1.kind == :leaf and &1.root == root))]

      item ->
        [item]
    end
  end

  # The items up to and including the last of the failing step's block.
  defp through(items, []), do: items

  defp through(items, block) do
    last = List.last(block)
    Enum.take_while(items, &(&1 != last)) ++ [last]
  end

  defp cutoff(trace, block) do
    ordinals =
      Enum.flat_map(block, fn item ->
        own = Map.get(trace.command_fold_ordinals, item.position)
        folds = for %{fold_index: fold} <- item.entries, fold != nil, do: fold
        if own, do: [own | folds], else: folds
      end)

    if ordinals != [], do: Enum.max(ordinals)
  end

  defp short_name(%module{}), do: module |> Module.split() |> List.last()
  defp short_name(other), do: inspect(other)

  # ==========================================================================
  # Reproduction
  # ==========================================================================

  defp reproduction_section(report) do
    {replay_label, replay} = replay_lines(report)

    lines =
      binding_lines(report) ++
        [
          {:comment, "Rerun from the seed:"},
          {:code, bind(FailureReport.reproduction_command(report), report)},
          :blank
        ] ++
        regenerate_lines(report) ++
        [
          {:comment, replay_label},
          replay
        ]

    %Section{heading: "Reproduction", fence: "elixir", lines: lines}
  end

  # A report that records no target has no name to regenerate with.
  defp regenerate_lines(report) do
    case FailureReport.expansion_command(report) do
      nil ->
        []

      call ->
        [{:comment, "Regenerate the failing variant:"}, {:code, bind(call, report)}, :blank]
    end
  end

  # `targets = [...]` once, and a line naming each place in it that holds a
  # value no source can rebuild.
  defp binding_lines(%FailureReport{targets: []}), do: []

  defp binding_lines(report) do
    binding = {:code, "targets = " <> FailureReport.targets_source(report)}

    case opaque(report.targets) do
      [] ->
        [binding, :blank]

      places ->
        held = Enum.map_join(places, " and ", fn {what, path} -> "#{what} at #{path}" end)
        [binding, {:comment, "targets holds #{held}; rebuild the list as the test does."}, :blank]
    end
  end

  # Every call names the bound list instead of repeating it.
  defp bind(call, %FailureReport{targets: []}), do: call

  defp bind(call, report),
    do:
      String.replace(
        call,
        "targets: " <> FailureReport.targets_source(report),
        "targets: targets"
      )

  defp opaque(targets) do
    targets
    |> Enum.flat_map(fn {_adapter, entry} ->
      Enum.flat_map(entry, fn {key, value} -> opaque_in(value, [key]) end)
    end)
    |> Enum.uniq()
  end

  defp opaque_in(value, path) when is_pid(value), do: [{"a pid", path_text(path)}]
  defp opaque_in(value, path) when is_reference(value), do: [{"a reference", path_text(path)}]
  defp opaque_in(value, path) when is_port(value), do: [{"a port", path_text(path)}]
  defp opaque_in(value, path) when is_function(value), do: [{"a function", path_text(path)}]
  defp opaque_in(%_{}, _path), do: []

  defp opaque_in(map, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> opaque_in(value, [key | path]) end)

  defp opaque_in(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> opaque_in(value, [index | path]) end)
  end

  defp opaque_in(tuple, path) when is_tuple(tuple), do: opaque_in(Tuple.to_list(tuple), path)

  defp opaque_in(_value, _path), do: []

  defp path_text(path), do: path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)

  defp replay_lines(%FailureReport{replay_status: :reproduced} = report),
    do: {"The artifact reproduced the failure. Replay it again:", replay_call(report)}

  defp replay_lines(%FailureReport{replay_status: :not_reproduced} = report),
    do:
      {"The artifact did not reproduce the recorded failure (this run failed another way). " <>
         "Replay it again:", replay_call(report)}

  defp replay_lines(report), do: {replay_label(report), replay_call(report)}

  # An artifact no shrink attempt changed (shrinking was off) holds the
  # failing run as it was found.
  defp replay_label(%FailureReport{shrink_iterations: 0, replay: %{}}),
    do: "Replay the unshrunk failure:"

  defp replay_label(_report), do: "Replay the shrunk failure:"

  defp replay_call(%FailureReport{replay_path: path} = report) when is_binary(path),
    do: {:code, bind(FailureReport.replay_command(report), report)}

  defp replay_call(%FailureReport{replay_status: :disabled}),
    do: {:text, "(no artifact: the run was given replay_dir: false)"}

  defp replay_call(%FailureReport{replay_status: {:write_failed, reason}}),
    do: {:text, "(no artifact: writing it failed: #{inspect(reason)})"}

  defp replay_call(%FailureReport{replay: {:refused, refusal}}),
    do:
      {:text,
       "(no artifact: refused, because " <>
         "#{PropertyDamage.ReplayArtifact.describe_refusal(refusal)} holds a function, pid, " <>
         "reference or port, which no file can hold)"}

  defp replay_call(%FailureReport{replay_status: :unavailable}),
    do: {:text, "(no artifact: this failure is replayed from its seed only)"}

  defp replay_call(_report), do: {:text, "(no artifact recorded for this report)"}

  # ==========================================================================
  # Names
  # ==========================================================================

  defp variant_name(%FailureReport{variant: %{name: name}}), do: name

  defp variant_name(%FailureReport{targets: [{adapter, entry} | _]}),
    do: Keyword.get(entry, :name) || Target.default_name(adapter)

  defp variant_name(_report), do: nil

  defp reference_name(%FailureReport{targets: [{adapter, entry} | _]}),
    do: Keyword.get(entry, :name) || Target.default_name(adapter)

  defp reference_name(_report), do: nil
end
