defmodule PropertyDamage.Export.Common do
  @moduledoc """
  Shared utilities for export functionality.

  Provides common functions for:
  - Extracting commands from failure reports
  - Serializing commands and values to various formats
  - Extracting ref bindings from events
  - Generating metadata (timestamps, headers, etc.)
  """

  alias PropertyDamage.{FailureReport, Sequence, Ref}
  alias PropertyDamage.Export.HTTPSpec

  # ============================================================================
  # Command Extraction
  # ============================================================================

  @doc """
  Extracts the command list from a failure report.

  Returns the shrunk sequence as a list of command structs.
  """
  @spec extract_commands(FailureReport.t()) :: [struct()]
  def extract_commands(%FailureReport{shrunk_sequence: sequence}) do
    Sequence.to_list(sequence)
  end

  @doc """
  Extracts metadata from a failure report for documentation headers.
  """
  @spec extract_metadata(FailureReport.t()) :: map()
  def extract_metadata(%FailureReport{} = report) do
    %{
      seed: report.seed,
      failure_type: report.failure_type,
      failure_message: report.failure_message,
      check_name: report.check_name,
      failed_at_index: report.failed_at_index,
      timestamp: report.timestamp,
      model: report.model,
      adapter: report.adapter
    }
  end

  # ============================================================================
  # HTTPSpec Resolution
  # ============================================================================

  @doc """
  Gets the HTTPSpec for a command from an adapter.

  If the adapter implements `http_spec/2`, calls it.
  Otherwise, returns nil (the script generator should handle this gracefully).
  """
  @spec get_http_spec(struct(), module() | nil, map()) :: HTTPSpec.t() | nil
  def get_http_spec(_command, nil, _context), do: nil

  def get_http_spec(command, adapter, context) do
    if function_exported?(adapter, :http_spec, 2) do
      adapter.http_spec(command, context)
    else
      nil
    end
  end

  # ============================================================================
  # Ref Extraction
  # ============================================================================

  @doc """
  Extracts ref bindings from events.

  Looks for fields ending in `_ref` or `_id` in events and builds a map
  of command_index -> field_name -> value.

  This is used to track which refs are bound by which commands.
  """
  @spec extract_ref_bindings([struct()], [PropertyDamage.EventLog.Entry.t()]) :: map()
  def extract_ref_bindings(commands, events) do
    # Group events by command index
    events_by_command =
      events
      |> Enum.filter(&(&1.command_index != nil))
      |> Enum.group_by(& &1.command_index)

    # For each command, extract potential ref bindings from its events
    commands
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {_cmd, idx}, acc ->
      case Map.get(events_by_command, idx, []) do
        [] ->
          acc

        cmd_events ->
          bindings = extract_bindings_from_events(cmd_events)

          if map_size(bindings) > 0 do
            Map.put(acc, idx, bindings)
          else
            acc
          end
      end
    end)
  end

  defp extract_bindings_from_events(events) do
    Enum.reduce(events, %{}, fn entry, acc ->
      event = entry.event

      event
      |> Map.from_struct()
      |> Enum.filter(fn {key, value} ->
        is_ref_field?(key) and is_bindable_value?(value)
      end)
      |> Enum.into(acc)
    end)
  end

  defp is_ref_field?(key) do
    key_str = to_string(key)
    String.ends_with?(key_str, "_ref") or String.ends_with?(key_str, "_id") or key == :id
  end

  defp is_bindable_value?(value) when is_binary(value), do: true
  defp is_bindable_value?(value) when is_integer(value), do: true
  defp is_bindable_value?(_), do: false

  # ============================================================================
  # Value Serialization
  # ============================================================================

  @doc """
  Serializes a value for use in scripts.

  Handles refs, atoms, strings, numbers, lists, and maps.
  """
  @spec serialize_value(term(), keyword()) :: String.t()
  def serialize_value(value, opts \\ [])

  def serialize_value(%Ref{} = ref, opts) do
    format = Keyword.get(opts, :format, :elixir)
    ref_var = Keyword.get(opts, :ref_var, "refs")
    serialize_ref(ref, format, ref_var)
  end

  def serialize_value(value, opts) when is_atom(value) do
    format = Keyword.get(opts, :format, :elixir)

    case format do
      :elixir -> inspect(value)
      :json -> Jason.encode!(to_string(value))
      :python -> Jason.encode!(to_string(value))
      :bash -> Jason.encode!(to_string(value))
    end
  end

  def serialize_value(value, opts) when is_binary(value) do
    format = Keyword.get(opts, :format, :elixir)

    case format do
      :elixir -> inspect(value)
      _ -> Jason.encode!(value)
    end
  end

  def serialize_value(value, _opts) when is_number(value), do: to_string(value)

  def serialize_value(value, opts) when is_list(value) do
    format = Keyword.get(opts, :format, :elixir)

    case format do
      :elixir ->
        items = Enum.map(value, &serialize_value(&1, opts)) |> Enum.join(", ")
        "[#{items}]"

      _ ->
        Jason.encode!(value)
    end
  end

  def serialize_value(value, opts) when is_map(value) do
    format = Keyword.get(opts, :format, :elixir)

    case format do
      :elixir ->
        items =
          value
          |> Enum.map(fn {k, v} ->
            "#{serialize_map_key(k)}: #{serialize_value(v, opts)}"
          end)
          |> Enum.join(", ")

        "%{#{items}}"

      _ ->
        Jason.encode!(value)
    end
  end

  def serialize_value(value, opts) do
    format = Keyword.get(opts, :format, :elixir)

    case format do
      :elixir -> inspect(value)
      _ -> Jason.encode!(value)
    end
  end

  defp serialize_map_key(key) when is_atom(key), do: to_string(key)
  defp serialize_map_key(key), do: inspect(key)

  defp serialize_ref(%Ref{label: label}, :elixir, ref_var) do
    "#{ref_var}[#{inspect(sanitize_label(label))}]"
  end

  defp serialize_ref(%Ref{label: label}, :python, ref_var) do
    "#{ref_var}[#{inspect(sanitize_label(label))}]"
  end

  defp serialize_ref(%Ref{label: label}, :bash, ref_var) do
    # Bash uses uppercase var names typically
    var_name = String.upcase(ref_var)
    "${#{var_name}_#{sanitize_label(label)}}"
  end

  defp serialize_ref(%Ref{label: label}, :json, _ref_var) do
    # For JSON, we just use a placeholder that will be substituted
    "{{REF_#{sanitize_label(label)}}}"
  end

  defp sanitize_label(nil), do: "unknown"

  defp sanitize_label(label) when is_binary(label) do
    label
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.downcase()
  end

  defp sanitize_label(label), do: sanitize_label(to_string(label))

  # ============================================================================
  # Command Serialization
  # ============================================================================

  @doc """
  Extracts the command name (last part of module name).
  """
  @spec command_name(struct()) :: String.t()
  def command_name(command) do
    command.__struct__
    |> Module.split()
    |> List.last()
  end

  @doc """
  Extracts command fields as a map (excluding __struct__).
  """
  @spec command_fields(struct()) :: map()
  def command_fields(command) do
    command
    |> Map.from_struct()
    |> Map.delete(:__struct__)
  end

  @doc """
  Serializes a command to a readable string for comments.
  """
  @spec command_to_comment(struct()) :: String.t()
  def command_to_comment(command) do
    name = command_name(command)
    fields = command_fields(command)

    if map_size(fields) == 0 do
      "%#{name}{}"
    else
      field_strs =
        fields
        |> Enum.map(fn {k, v} -> "#{k}: #{format_comment_value(v)}" end)
        |> Enum.join(", ")

      "%#{name}{#{field_strs}}"
    end
  end

  defp format_comment_value(%Ref{label: label}), do: "ref(#{label || "?"})"
  defp format_comment_value(value) when is_binary(value), do: inspect(value)
  defp format_comment_value(value) when is_atom(value), do: ":#{value}"
  defp format_comment_value(value), do: inspect(value, limit: 3)

  # ============================================================================
  # Header Generation
  # ============================================================================

  @doc """
  Generates a header comment for scripts.
  """
  @spec generate_header(map(), keyword()) :: String.t()
  def generate_header(metadata, opts \\ []) do
    format = Keyword.get(opts, :format, :elixir)
    timestamp = format_timestamp(metadata.timestamp)

    failure_desc =
      case metadata.check_name do
        nil -> to_string(metadata.failure_type)
        check -> "#{check} check failed"
      end

    case format do
      :elixir ->
        """
        # Failure Reproduction Script
        # Generated: #{timestamp}
        # Failure: #{failure_desc}
        # Seed: #{metadata.seed}
        """

      :bash ->
        """
        # Failure Reproduction Script
        # Generated: #{timestamp}
        # Failure: #{failure_desc}
        # Seed: #{metadata.seed}
        """

      :python ->
        ~s("""
        Failure Reproduction Script
        Generated: #{timestamp}
        Failure: #{failure_desc}
        Seed: #{metadata.seed}
        """)
    end
  end

  defp format_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: inspect(other)

  # ============================================================================
  # Filename Generation
  # ============================================================================

  @doc """
  Generates a filename for the export based on seed and format.
  """
  @spec generate_filename(FailureReport.t(), atom()) :: String.t()
  def generate_filename(%FailureReport{seed: seed}, format) do
    ext = extension_for_format(format)
    "reproduce_#{seed}#{ext}"
  end

  defp extension_for_format(:exunit), do: ".exs"
  defp extension_for_format(:elixir), do: ".exs"
  defp extension_for_format(:curl), do: ".sh"
  defp extension_for_format(:bash), do: ".sh"
  defp extension_for_format(:python), do: ".py"
  defp extension_for_format(:livebook), do: ".livemd"
  defp extension_for_format(_), do: ".txt"
end
