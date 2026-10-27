defmodule PropertyDamage.FailureReport.Formatter do
  @moduledoc false

  alias PropertyDamage.{Failure, FailureReport, Sequence}

  alias PropertyDamage.FailureReport.{Layout, Render}

  @type format :: :terminal | :markdown | :json | :compact

  @doc """
  Format a failure report as `:terminal` text, `:markdown`, `:json` or a
  `:compact` one-line summary.

  The terminal and markdown formats print one layout (DR-055, DR-056): the
  banner and the seed, then the Failure, Minimal Reproduction, Projections and
  Reproduction sections, with every step and every event in full. The
  markdown format is the terminal text without color, each section's body in
  a fenced block. The JSON format keeps every field of the report.

  ## Options

  - `:color` - Use ANSI colors in the terminal format (default: true)
  - `:indent` - Indentation for JSON (default: 2)
  """
  @spec format(FailureReport.t(), format(), keyword()) :: String.t()
  def format(report, format \\ :terminal, opts \\ [])

  def format(report, :terminal, opts),
    do: report |> Layout.build() |> Render.terminal(Keyword.get(opts, :color, true))

  def format(report, :markdown, _opts), do: report |> Layout.build() |> Render.markdown()
  def format(report, :json, opts), do: format_json(report, opts)
  def format(report, :compact, _opts), do: format_compact(report)

  # ============================================================================
  # JSON Format
  # ============================================================================

  defp serialize_other_failure(%{variant: variant, root: root, failure: failure}) do
    name = Failure.name(failure)

    %{
      "variant" => %{"index" => variant.index, "name" => variant.name},
      "root" => root,
      "type" => to_string(Failure.kind(failure)),
      "check_name" => name && FailureReport.format_name(name),
      "message" => FailureReport.failure_message(failure)
    }
  end

  defp format_json(report, opts) do
    indent = Keyword.get(opts, :indent, 2)

    data = %{
      "type" => "property_damage_failure_report",
      "version" => "1.0",
      "timestamp" => DateTime.to_iso8601(report.timestamp),
      "location" => %{
        "run_number" => report.run_number,
        "failed_at_index" => report.failed_at_index,
        "seed" => report.seed
      },
      "failure" => %{
        "type" => to_string(FailureReport.failure_type(report)),
        "check_name" =>
          FailureReport.check_name(report) &&
            FailureReport.format_name(FailureReport.check_name(report)),
        "message" => FailureReport.failure_message(report),
        "summary" => FailureReport.failure_type_summary(report)
      },
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
        serialize_sequence(FailureReport.shrunk_sequence(report), report.command_labels),
      "reproduction" => FailureReport.reproduction_command(report),
      "other_failures" => Enum.map(report.other_failures, &serialize_other_failure/1),
      "reference_trace" => serialize_reference_trace(report),
      "reference_projections" =>
        report.reference_state_at_failure &&
          serialize_projections(report.reference_state_at_failure)
    }

    # Add optional sections
    data =
      if report.state_at_failure && map_size(report.state_at_failure) > 0 do
        Map.put(data, "projections", serialize_projections(report.state_at_failure))
      else
        data
      end

    data =
      if FailureReport.event_log(report) != [] do
        Map.put(data, "event_log", serialize_event_log(FailureReport.event_log(report)))
      else
        data
      end

    data =
      if FailureReport.idempotency_violation(report) do
        Map.put(
          data,
          "idempotency_violation",
          serialize_idempotency(FailureReport.idempotency_violation(report))
        )
      else
        data
      end

    Jason.encode!(data, pretty: indent > 0)
  end

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
        serialize_sequence(FailureReport.shrunk_sequence(report), report.command_labels),
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
        "type" => module_name(cmd.__struct__),
        "fields" => cmd |> Map.from_struct() |> serialize_map(),
        "label" => Map.get(command_labels, idx)
      }
    end)
  end

  defp serialize_projections(projections) do
    for {projection, state} <- projections, into: %{} do
      {module_name(projection), serialize_value(state)}
    end
  end

  defp serialize_event_log(event_log) do
    Enum.map(event_log, fn entry ->
      %{
        "source" => to_string(entry.source),
        "command_index" => entry.command_index,
        "branch_id" => entry.branch_id,
        "event_type" => module_name(entry.event.__struct__),
        "event" => entry.event |> Map.from_struct() |> serialize_map()
      }
    end)
  end

  defp serialize_idempotency(violation) do
    %{
      "command" => module_name(violation.command.__struct__),
      "command_index" => violation.command_index,
      "attempts" =>
        Enum.map(violation.attempts, fn att ->
          %{
            "attempt" => att.attempt,
            "is_retry" => att.is_retry,
            "events" => Enum.map(att.events, &module_name(&1.__struct__))
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
    %{"_type" => module_name(mod), "_fields" => struct |> Map.from_struct() |> serialize_map()}
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

  # ============================================================================
  # Compact Format
  # ============================================================================

  defp format_compact(report) do
    type = FailureReport.failure_type_summary(report)
    cmd_count = Sequence.command_count(FailureReport.shrunk_sequence(report))

    origin_tag =
      case report.error_origin do
        :test_code_error -> "[TEST CODE ERROR]"
        :sut_error -> "[SUT BUG]"
        _ -> "[FAIL]"
      end

    "#{origin_tag} #{type} | run=#{report.run_number + 1} cmd=#{FailureReport.failure_index(report)} " <>
      "shrunk=#{cmd_count} seed=#{report.seed}"
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp module_name(module) when is_atom(module) do
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
