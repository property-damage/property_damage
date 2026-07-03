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
  # Value Serialization
  # ============================================================================

  @doc """
  Serializes a value for use in scripts.

  Handles atoms, strings, numbers, lists, and maps.
  """
  @spec serialize_value(term(), keyword()) :: String.t()
  def serialize_value(value, opts \\ [])

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
        items = Enum.map_join(value, ", ", &serialize_value(&1, opts))
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
          |> Enum.map_join(", ", fn {k, v} ->
            "#{serialize_map_key(k)}: #{serialize_value(v, opts)}"
          end)

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
  def generate_filename(%FailureReport{seed: seed} = report, format) do
    ext = extension_for_format(format)
    "reproduce_#{seed}_#{failure_signature(report)}#{ext}"
  end

  # A short, stable content signature so two distinct failures that happen to
  # share a seed (across models, or a randomly-seeded run) don't silently
  # overwrite each other, while an identical failure maps to the same file.
  defp failure_signature(%FailureReport{} = report) do
    {report.failure_type, report.check_name, report.failure_reason,
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
