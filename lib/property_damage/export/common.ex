defmodule PropertyDamage.Export.Common do
  @moduledoc false

  alias PropertyDamage.{FailureReport, Placeholder, Sequence}

  # ============================================================================
  # Command Extraction
  # ============================================================================

  @doc """
  Extracts the command list from a failure report.

  Returns the shrunk sequence as a list of command structs.
  """
  @spec extract_commands(FailureReport.t()) :: [struct()]
  def extract_commands(%FailureReport{} = report) do
    Sequence.to_list(FailureReport.shrunk_sequence(report))
  end

  @doc """
  Extracts metadata from a failure report for documentation headers.
  """
  @spec extract_metadata(FailureReport.t()) :: map()
  def extract_metadata(%FailureReport{} = report) do
    %{
      seed: report.seed,
      failure_type: FailureReport.failure_type(report),
      failure_message: FailureReport.failure_message(report),
      check_name: FailureReport.check_name(report),
      failed_at_index: report.failed_at_index,
      timestamp: report.timestamp,
      model: report.model,
      adapter: report.adapter
    }
  end

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
      # Sort by the field name's string form for a stable comment: map key
      # enumeration order is not guaranteed and varies with atom intern order.
      field_strs =
        fields
        |> Enum.sort_by(fn {k, _} -> to_string(k) end)
        |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{format_comment_value(v)}" end)

      "%#{name}{#{field_strs}}"
    end
  end

  defp format_comment_value(%Placeholder{event_module: mod, path: path}) do
    "external(#{mod |> Module.split() |> List.last()}.#{Enum.join(path, ".")})"
  end

  defp format_comment_value(value) when is_binary(value), do: inspect(value)
  defp format_comment_value(value) when is_atom(value), do: ":#{value}"

  # A placeholder nested in a collection renders as `external(...)` like a
  # top-level one, instead of leaking its raw struct. Collections without a
  # placeholder keep `inspect/1`'s output (including `limit: 3` truncation).
  defp format_comment_value(value) when is_list(value) do
    if contains_placeholder?(value) do
      "[" <> Enum.map_join(value, ", ", &format_comment_value/1) <> "]"
    else
      inspect(value, limit: 3)
    end
  end

  defp format_comment_value(value) when is_map(value) and not is_struct(value) do
    if contains_placeholder?(value) do
      "%{" <> Enum.map_join(value, ", ", &format_comment_pair/1) <> "}"
    else
      inspect(value, limit: 3)
    end
  end

  defp format_comment_value(value), do: inspect(value, limit: 3)

  defp format_comment_pair({key, value}) when is_atom(key),
    do: "#{key}: #{format_comment_value(value)}"

  defp format_comment_pair({key, value}),
    do: "#{format_comment_value(key)} => #{format_comment_value(value)}"

  defp contains_placeholder?(%Placeholder{}), do: true

  defp contains_placeholder?(value) when is_list(value),
    do: Enum.any?(value, &contains_placeholder?/1)

  defp contains_placeholder?(%_{}), do: false

  defp contains_placeholder?(value) when is_map(value),
    do: Enum.any?(value, fn {_k, v} -> contains_placeholder?(v) end)

  defp contains_placeholder?(_value), do: false

  # ============================================================================
  # Filename Generation
  # ============================================================================

  @doc """
  Generates a filename for the export based on seed and format.
  """
  @spec generate_filename(FailureReport.t(), atom()) :: String.t()
  def generate_filename(%FailureReport{seed: seed} = report, format) do
    ext = extension_for_format(format)
    "reproduce_#{seed}_#{failure_signature(report)}#{ext}"
  end

  # A short, stable content signature so two distinct failures that happen to
  # share a seed (across models, or a randomly-seeded run) don't silently
  # overwrite each other, while an identical failure maps to the same file.
  defp failure_signature(%FailureReport{} = report) do
    {FailureReport.failure_type(report), FailureReport.check_name(report), report.failure_reason,
     FailureReport.shrunk_sequence(report)}
    |> :erlang.phash2()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp extension_for_format(:exunit), do: ".exs"
  defp extension_for_format(:elixir), do: ".exs"
  defp extension_for_format(:curl), do: ".sh"
  defp extension_for_format(:bash), do: ".sh"
  defp extension_for_format(:python), do: ".py"
  defp extension_for_format(:livebook), do: ".livemd"
  defp extension_for_format(_), do: ".txt"
end
