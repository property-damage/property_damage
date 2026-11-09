defmodule PropertyDamage.FailureReport.Document do
  @moduledoc """
  A failure report as one JSON-ready document.

  `build/2` returns a map with string keys. The `:json` format of a failure
  report writes it, `PropertyDamage.Persistence.export_json/1`
  exports it, `PropertyDamage.FailureReport.Bundle.build/2` returns it, and
  every HTML failure page carries it in the script tag `pd-bundle`. A program
  reads one key set whichever way it got the document.

  The document never copies the page's step, event or section text: it names
  them by id and the page prints them. It holds no process id and lists
  everything in a stable order.

  When the report's sections cannot be built, `failure.fields`, `listing` and
  `sections` are empty lists and every other member is still written.

  ## Options

    * `:log` - a tag filter for the log lines, as for the terminal format
    * `:sources` - when `true`, the document also holds the source members
      (`modules`, `ids`, `missing_sources`, `redactions`, see below); default
      `false`

  ## Keys

  | key | type | meaning |
  |---|---|---|
  | `format` | integer | the document format, `2` |
  | `pd_version` | string | the version of this library |
  | `timestamp` | string | when the failure was found, ISO 8601 |
  | `report_kind` | string | the outcome of the run: `check_failed`, `diverged` and so on |
  | `model` | string | the model module |
  | `location` | map | `run_number`, `failed_at_index` and `seed` |
  | `failure` | map | `kind`, `check_name`, `message`, `summary`, `meaning` (the text the kind prints under "What this checks"), `fields` (the Failure section's lines, each `{id, label, value}` in print order) and, for a check failure, `projection` |
  | `context` | list | the items of "What this checks", each `{id, label, name, text, missing}` |
  | `error_origin` | map | `origin`, `reason`, `confidence`, `hint` and `is_test_code_error` |
  | `shrinking` | map | `original_commands`, `shrunk_commands`, `iterations`, `time_ms` and `stop` |
  | `sequence` | list | the shrunk sequence, each `{index, type, fields, label}` |
  | `setup_commands`, `teardown_commands` | list | the commands of the run's setup and teardown, as `inspect/1` prints them |
  | `reproduction` | string | the command that reruns the failure |
  | `other_failures` | list | the failures of the other targets, each `{variant, root, kind, check_name, message}` |
  | `variant`, `targets` | map, list | the failing target and the targets of the run |
  | `compare`, `compare_counts` | map | the convergence options of a comparison and the counts of each compared observation |
  | `stutter`, `max_commands` | string, integer | the run options of the same names |
  | `reference_trace`, `reference_projections` | map | the reference side of a comparison; `null` for any other failure |
  | `logs` | map | the log lines the terminal shows, after the same filter (see below) |
  | `listing` | list | one map per target, the reference first (see below) |
  | `sections` | list | one `{id, title, fence, data}` per `## ` section, in page order |
  | `projections` | map | the projection state at the failure; present when not empty |
  | `event_log` | list | the events of the run; present when not empty |
  | `idempotency_violation` | map | present for an idempotency failure |
  | `modules` | list | with `sources: true`: one map per module behind the failure (see below) |
  | `ids` | list | with `sources: true`: every id the document declares, once each, in a stable order |
  | `missing_sources` | list | with `sources: true`: the paths of source files that could not be read |
  | `redactions` | map | with `sources: true`: `count` of literals replaced in the sources of the modules in adapter files, and the `rule` applied |

  ### Logs

  `logs` holds the log lines the terminal shows, after the same filter:
  `filter` (`only`, `except` and `source`, `"log_option"` or `"PD_LOG"`; null
  without a filter), `unknown_tags`, the `setup` lines once, and for the
  failing `target` and, when the report has one, the `reference`: its `name`,
  the `adapter_setup` and `adapter_teardown` lines and each `steps` entry's
  `label`, `root` and `lines`. A line is `{"kind": "line", "message", "tags",
  "file", "line", "offset_ms", "attempt"}`, its message as plain text; a gap is
  `{"kind": "gap", "attempts", "lines"}`. A hidden line is in none of these.

  ### Listing

  A target is `{name, role, adapter, steps, adapter_setup, adapter_teardown,
  untied}`. `role` is `"variant"` or `"reference"`, and `adapter` is the
  module as `inspect/1` prints it. A step is `{id, label, command, ran_as,
  failed, entries}`: `label` is the label the page prints (`[3]`, `[3.1]`,
  `[setup 0]`), `command` the module of the command, `ran_as` the note
  that says what a root ran in place of a listed entry (else `null`), and
  `failed` marks the step the failure is reported at. An entry is `{id, n, event}`:
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
  adapter of every target, each module once, in that order. Each adapter is
  followed by the modules its `delegate_execution` calls name in `to:`
  (depth first, role `adapter`), as `__pd_sub_adapters__/0` of the adapter
  reports them; a bare `@behaviour` adapter has none. A module is
  `{module, role, moduledoc, file, lines, source, resolution, functions,
  redactions}`:

    * `role` is `model`, `projection`, `command`, `event` or `adapter`;
    * `file` is the path of the source file relative to the project root
      (the current directory), so a shared page reveals no directory above
      the project; a file outside the project is named by its base name.
      `missing_sources` and a missing `source` use the same form;
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
  no ranges, so its functions get a `null` id. A function the file does not
  define at the top level of its module (one a macro injects, or one
  generated in a loop) has `null` for both, as has every function of a module
  whose file is missing, cannot be read or is `"nofile"`.

  ### Ids

  Ids are opaque: a reader finds one by equality in `ids` and never splits
  it. `failure:<label>` and `context:<label>` use the label as printed; a
  label that repeats gets an ordinal from the second occurrence (`:2`).
  `step:<target>:<label>`, `entry:<target>:<label>:<n>` and `section:<title>`
  use the text the page prints. `source:<Module>.<function>/<arity>` names a
  function `PropertyDamage.Docs.fetch/1` lists, private ones included. A
  function with no range (one a macro injects, such as `timeout/1`, or any
  function of a module whose file is missing, unreadable or `"nofile"`) has
  `null` for its id and is not in `ids`: an id the document declares must point
  at lines a reader can check. Its name, arity and doc stay listed.

  ### Redaction

  The source of every module whose `file` is the file of an adapter (a sub-adapter too) in the
  document passes through `PropertyDamage.FailureReport.Bundle.Redaction`, which
  replaces secret-shaped string literals. A file shows the same text through
  each module defined in it, so a model above an adapter in one file is
  redacted too. Each module's `redactions` counts its own replacements and
  the top-level count sums them, so a literal in a shared file counts once
  per module that shows the file. The source of a module in a file no adapter
  shares is not scanned.
  """

  alias PropertyDamage.{Failure, FailureReport, Sequence, Target}
  alias PropertyDamage.Failure.Naming
  alias PropertyDamage.FailureReport.Bundle.{Redaction, Sources}
  alias PropertyDamage.FailureReport.{Context, Layout}

  @format 2

  @doc """
  Returns the document of `report` as a map with string keys.

  `opts` are the options the layout of the page takes, such as `log:`, and
  `sources: true` to add the source members.
  """
  @spec build(FailureReport.t(), keyword()) :: map()
  def build(%FailureReport{} = report, opts \\ []) do
    items = Layout.context_items(report, opts)
    data = layout_data(report, opts)
    sections = if data, do: data.layout.sections, else: []
    targets = if data, do: data.targets, else: []
    listing_id = listing_section_id(sections)

    failure = failure_member(report, sections, items)
    context = context(items)
    listing = Enum.map(targets, &target(&1, report, listing_id))
    section_entries = Enum.map(sections, &section(&1, data))

    %{
      "format" => @format,
      "pd_version" => to_string(Application.spec(:property_damage, :vsn)),
      "timestamp" => DateTime.to_iso8601(FailureReport.timestamp(report)),
      "report_kind" => report.report_kind && to_string(report.report_kind),
      "model" => FailureReport.model(report) && inspect(FailureReport.model(report)),
      "location" => %{
        "run_number" => FailureReport.run_number(report),
        "failed_at_index" => report.failed_at_index,
        "seed" => FailureReport.seed(report)
      },
      "failure" => Map.merge(failure, check_members(report)),
      "context" => context,
      "error_origin" => %{
        "origin" => report.error_origin && to_string(report.error_origin),
        "reason" => get_in(report.error_origin_details, [:reason]),
        "confidence" =>
          report.error_origin_details && to_string(report.error_origin_details.confidence),
        "hint" => get_in(report.error_origin_details, [:evidence, :hint]),
        "is_test_code_error" => report.error_origin == :test_code_error
      },
      "shrinking" => %{
        "original_commands" => Sequence.command_count(report.original_sequence),
        "shrunk_commands" => Sequence.command_count(FailureReport.shrunk_sequence(report)),
        "iterations" => report.shrink_iterations,
        "time_ms" => report.shrink_time_ms,
        "stop" => report.shrink_stop && to_string(report.shrink_stop)
      },
      "sequence" =>
        serialize_sequence(
          FailureReport.shrunk_sequence(report),
          FailureReport.command_labels(report)
        ),
      "setup_commands" => Enum.map(FailureReport.setup_commands(report), &inspect/1),
      "teardown_commands" => Enum.map(FailureReport.teardown_commands(report), &inspect/1),
      "reproduction" => FailureReport.reproduction_command(report),
      "other_failures" => Enum.map(report.other_failures, &serialize_other_failure/1),
      "variant" => report.variant && serialize_value(report.variant),
      "targets" => Enum.map(report.targets, &serialize_target/1),
      "compare" => serialize_value(Map.new(report.compare)),
      "compare_counts" =>
        Map.new(report.compare_counts, fn {key, counts} ->
          {Naming.format_name(key), counts}
        end),
      "stutter" => report.stutter && inspect(report.stutter),
      "max_commands" => report.max_commands,
      "reference_trace" => serialize_reference_trace(report),
      "reference_projections" =>
        report.reference_state_at_failure &&
          serialize_projections(report.reference_state_at_failure),
      "logs" => serialize_logs(Layout.logs(report, opts)),
      "listing" => listing,
      "sections" => section_entries
    }
    |> put_when(
      report.state_at_failure && map_size(report.state_at_failure) > 0,
      "projections",
      fn -> serialize_projections(report.state_at_failure) end
    )
    |> put_when(FailureReport.event_log(report) != [], "event_log", fn ->
      serialize_event_log(FailureReport.event_log(report))
    end)
    |> put_when(FailureReport.idempotency_violation(report), "idempotency_violation", fn ->
      serialize_idempotency(FailureReport.idempotency_violation(report))
    end)
    |> put_sources(
      report,
      targets,
      [failure_ids(failure), context, listing, section_entries],
      opts
    )
  end

  # The page layout: the sections and the steps of each target. A report whose
  # sections cannot be built (a projection whose relations raise, say) still
  # yields the rest of the document, with no fields, sections or listing.
  defp layout_data(report, opts) do
    Layout.bundle_data(report, opts)
  rescue
    _cannot_build -> nil
  end

  defp put_when(document, condition, key, value) do
    if condition, do: Map.put(document, key, value.()), else: document
  end

  # The members that name a source: the modules behind the failure and the
  # ids a reader may cite.
  defp put_sources(document, report, targets, [failure_ids, context, listing, sections], opts) do
    if Keyword.get(opts, :sources, false) do
      adapters =
        for target <- targets, adapter = adapter_of(report, target.name), do: adapter

      {modules, missing, redacted} = Sources.build(report, targets, adapters)

      ids =
        Enum.uniq(
          failure_ids ++
            Enum.map(context, & &1["id"]) ++
            listing_ids(listing) ++
            Enum.map(sections, & &1["id"]) ++
            for(
              module <- modules,
              %{"id" => id} <- module["functions"],
              is_binary(id),
              do: id
            )
        )

      Map.merge(document, %{
        "modules" => modules,
        "ids" => ids,
        "missing_sources" => missing,
        "redactions" => %{"count" => redacted, "rule" => Redaction.rule()}
      })
    else
      document
    end
  end

  defp failure_ids(failure), do: Enum.map(failure["fields"], & &1["id"])

  # What names the failure: its check, its message and its summary.
  defp check_members(report) do
    name = FailureReport.check_name(report)

    Map.merge(
      %{
        "check_name" => name && Naming.format_name(name),
        "message" => FailureReport.failure_message(report),
        "summary" => FailureReport.kind_summary(report)
      },
      projection_entry(report)
    )
  end

  defp serialize_target({adapter, entry}) do
    %{
      "adapter" => inspect(adapter),
      "name" => Keyword.get(entry, :name),
      "config" => inspect(Keyword.get(entry, :config, %{})),
      "injectors" => Enum.map(Keyword.get(entry, :injectors, []), &inspect/1),
      "mocks" => inspect(Keyword.get(entry, :mocks, []))
    }
  end

  # ==========================================================================
  # Other failures and the projection of a check
  # ==========================================================================

  defp serialize_other_failure(%{variant: variant, root: root, failure: failure}) do
    name = Failure.name(failure)

    %{
      "variant" => %{"index" => variant.index, "name" => variant.name},
      "root" => root,
      "kind" => to_string(Failure.kind(failure)),
      "check_name" => name && Naming.format_name(name),
      "message" => FailureReport.failure_message(failure)
    }
  end

  # The projection that defines the failed check; the key is absent unless the
  # failure is a check failure.
  defp projection_entry(report), do: report |> FailureReport.failure_reason() |> projection_of()

  defp projection_of(%Failure{type: %Failure.Check{} = check}),
    do: %{"projection" => check.projection && inspect(check.projection)}

  defp projection_of(_failure), do: %{}

  # ==========================================================================
  # Failure and context
  # ==========================================================================

  defp failure_member(report, sections, [meaning | _]) do
    fields =
      for %{heading: "Failure", lines: lines} <- sections,
          {:field, _, _} = line <- lines,
          do: line

    ids = fields |> Enum.map(fn {:field, label, _parts} -> label end) |> with_ordinals()

    %{
      "kind" => report |> FailureReport.kind() |> to_string(),
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
  # Logs
  # ==========================================================================

  # The log lines the layout shows, after its filter.
  defp serialize_logs(logs) do
    %{
      "filter" => serialize_filter(logs.filter),
      "unknown_tags" => logs.unknown,
      "setup" => Enum.map(logs.setup, &serialize_log_entry/1),
      "target" => serialize_target_logs(logs.target),
      "reference" => logs.reference && serialize_target_logs(logs.reference)
    }
  end

  defp serialize_filter(nil), do: nil

  defp serialize_filter(%{only: only, except: except, source: source}) do
    %{
      "only" => only,
      "except" => except,
      "source" => if(source == :env, do: "PD_LOG", else: "log_option")
    }
  end

  defp serialize_target_logs(target) do
    %{
      "name" => target.name,
      "adapter_setup" => Enum.map(target.adapter_setup, &serialize_log_entry/1),
      "adapter_teardown" => Enum.map(target.adapter_teardown, &serialize_log_entry/1),
      "steps" =>
        for step <- target.steps do
          %{
            "label" => step.label,
            "root" => step.root,
            "lines" => Enum.map(step.lines, &serialize_log_entry/1)
          }
        end
    }
  end

  defp serialize_log_entry({:gap, gap}),
    do: %{"kind" => "gap", "attempts" => gap.attempts, "lines" => gap.lines}

  defp serialize_log_entry({:log, line}) do
    %{
      "kind" => "line",
      "message" => log_text(line.message),
      "tags" => Enum.map(line.tags, &to_string/1),
      "file" => line.file,
      "line" => line.line,
      "offset_ms" => line.offset_ms,
      "attempt" => line.attempt
    }
  end

  defp log_text({:text, text}), do: text

  defp log_text({:value, term}),
    do: inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity)

  # ==========================================================================
  # Reference trace and serialized values
  # ==========================================================================

  # The reference target's trace of the reported run; null when the report has
  # none. Its sequence is the plan both targets ran.
  defp serialize_reference_trace(%{reference_trace: nil}), do: nil

  defp serialize_reference_trace(%{reference_trace: trace} = report) do
    %{
      "target" => reference_name(report),
      "seed" => trace.seed,
      "run_number" => trace.run_number,
      "mint_epoch" => trace.mint_epoch,
      "plan_source" => trace.plan_source && to_string(trace.plan_source),
      "plan_fingerprint" => trace.plan_fingerprint,
      "sequence" =>
        serialize_sequence(
          FailureReport.shrunk_sequence(report),
          FailureReport.command_labels(report)
        ),
      "event_log" => serialize_event_log(FailureReport.reference_event_log(report))
    }
  end

  defp serialize_sequence(sequence, command_labels) do
    sequence
    |> Sequence.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      %{
        "index" => idx,
        "type" => short_name(cmd.__struct__),
        "fields" => cmd |> Map.from_struct() |> serialize_map(),
        "label" => Map.get(command_labels, idx)
      }
    end)
  end

  defp serialize_projections(projections) do
    for {projection, state} <- projections, into: %{} do
      {short_name(projection), serialize_value(state)}
    end
  end

  defp serialize_event_log(event_log) do
    Enum.map(event_log, fn entry ->
      %{
        "source" => to_string(entry.source),
        "command_index" => entry.command_index,
        "event_type" => short_name(entry.event.__struct__),
        "event" => entry.event |> Map.from_struct() |> serialize_map()
      }
    end)
  end

  defp serialize_idempotency(violation) do
    %{
      "command" => short_name(violation.command.__struct__),
      "command_index" => violation.command_index,
      "attempts" =>
        Enum.map(violation.attempts, fn att ->
          %{
            "attempt" => att.attempt,
            "is_retry" => att.is_retry,
            "events" => Enum.map(att.events, &short_name(&1.__struct__))
          }
        end),
      "mismatch" => mismatch_text(violation.mismatch)
    }
  end

  defp serialize_map(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {serialize_key(k), serialize_value(v)}
    end
  end

  # JSON keys must be strings. Atoms/binaries/numbers stringify cleanly;
  # tuple/ref/pid/struct keys (common in projection state) would crash
  # to_string, so they go through inspect.
  defp serialize_key(k) when is_atom(k), do: to_string(k)
  defp serialize_key(k) when is_binary(k), do: k
  defp serialize_key(k) when is_number(k), do: to_string(k)
  defp serialize_key(k), do: inspect(k)

  defp serialize_value(%{__struct__: mod} = struct) do
    %{"_type" => short_name(mod), "_fields" => struct |> Map.from_struct() |> serialize_map()}
  end

  defp serialize_value(map) when is_map(map), do: serialize_map(map)
  defp serialize_value(list) when is_list(list), do: Enum.map(list, &serialize_value/1)

  defp serialize_value(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> serialize_value()

  # Keep nil/booleans/numbers/strings as native JSON values
  defp serialize_value(nil), do: nil
  defp serialize_value(value) when is_boolean(value), do: value
  defp serialize_value(value) when is_number(value) or is_binary(value), do: value
  defp serialize_value(atom) when is_atom(atom), do: to_string(atom)

  # pids, ports, references, functions: not JSON-encodable, so inspect them
  defp serialize_value(other), do: inspect(other)

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp short_name(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  rescue
    # Erlang modules (e.g. :erlang) and plain atoms aren't Elixir modules
    ArgumentError -> Atom.to_string(module)
  end

  defp mismatch_text(mismatch) when is_exception(mismatch), do: Exception.message(mismatch)
  defp mismatch_text(other), do: inspect(other, pretty: true)

  defp reference_name(report) do
    case FailureReport.reference_target(report) do
      %{name: name} -> name
      nil -> nil
    end
  end
end
