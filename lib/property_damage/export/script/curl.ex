defmodule PropertyDamage.Export.Script.Curl do
  @moduledoc """
  Generates Bash scripts with curl commands for failure reproduction.

  The generated scripts:
  - Use curl for HTTP requests
  - Use jq for JSON parsing
  - Support environment variable for base URL
  - Track refs using shell variables
  """

  alias PropertyDamage.{FailureReport, Ref}
  alias PropertyDamage.Export.{Common, HTTPSpec}

  @doc """
  Generates a Bash/curl script from a failure report.

  ## Options

  - `:base_url` - Base URL for HTTP calls (required)
  - `:adapter` - Adapter module for HTTPSpec (optional)
  - `:env_var` - Environment variable name (default: "BASE_URL")
  - `:verbose` - Include extra comments (default: true)
  """
  @spec generate(FailureReport.t(), keyword()) :: String.t()
  def generate(%FailureReport{} = report, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:4000")
    env_var = Keyword.get(opts, :env_var, "BASE_URL")
    adapter = Keyword.get(opts, :adapter)
    verbose = Keyword.get(opts, :verbose, true)

    metadata = Common.extract_metadata(report)
    commands = Common.extract_commands(report)

    [
      generate_shebang(),
      generate_header(metadata),
      generate_setup(env_var, base_url),
      generate_steps(commands, report, adapter, env_var, verbose),
      generate_footer(metadata)
    ]
    |> Enum.join("\n")
  end

  # ============================================================================
  # Script Parts
  # ============================================================================

  defp generate_shebang do
    "#!/bin/bash"
  end

  defp generate_header(metadata) do
    failure_desc =
      case metadata.check_name do
        nil -> to_string(metadata.failure_type)
        check -> "#{check} check failed"
      end

    timestamp =
      case metadata.timestamp do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        _ -> DateTime.utc_now() |> DateTime.to_iso8601()
      end

    """
    # Failure Reproduction Script
    # Generated: #{timestamp}
    # Failure: #{failure_desc}
    # Seed: #{metadata.seed}
    #
    # Prerequisites: curl, jq
    # Run with: bash #{Common.generate_filename(%FailureReport{seed: metadata.seed}, :curl)}
    """
  end

  defp generate_setup(env_var, default_url) do
    """
    set -e  # Exit on error

    #{env_var}="${#{env_var}:-#{default_url}}"
    """
  end

  defp generate_steps(commands, report, adapter, env_var, verbose) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      is_failure_point = idx == report.failed_at_index
      generate_step(cmd, idx, adapter, env_var, is_failure_point, verbose)
    end)
    |> Enum.join("\n")
  end

  defp generate_step(command, index, adapter, env_var, is_failure_point, verbose) do
    step_num = index + 1
    cmd_name = Common.command_name(command)
    http_spec = Common.get_http_spec(command, adapter, %{})

    failure_marker = if is_failure_point, do: " (FAILURE POINT)", else: ""

    header =
      if verbose do
        """

        echo ""
        echo "=== Step #{step_num}: #{cmd_name}#{failure_marker} ==="
        """
      else
        ""
      end

    comment =
      if verbose do
        "# Command: #{Common.command_to_comment(command)}\n"
      else
        ""
      end

    curl_cmd = generate_curl_command(command, http_spec, env_var, index)

    header <> comment <> curl_cmd
  end

  defp generate_curl_command(command, nil, _env_var, index) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(command)
    var_name = "RESP#{index + 1}"

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    #{var_name}="<no HTTPSpec available for #{cmd_name}>"
    echo "Skipping #{cmd_name} - no HTTP mapping available"
    """
  end

  defp generate_curl_command(command, %HTTPSpec{} = spec, env_var, index) do
    var_name = "RESP#{index + 1}"
    method = HTTPSpec.method_string(spec)
    path = resolve_path_with_refs(spec, index)

    curl_parts = [
      "curl -s",
      "-X #{method}",
      "\"$#{env_var}#{path}\""
    ]

    # Add headers
    curl_parts = curl_parts ++ ["-H \"Content-Type: application/json\""]

    curl_parts =
      Enum.reduce(spec.headers, curl_parts, fn {name, value}, acc ->
        acc ++ ["-H \"#{name}: #{value}\""]
      end)

    # Add body if present
    curl_parts =
      if HTTPSpec.has_body?(spec) do
        body = resolve_body_with_refs(spec.body, command, index)
        curl_parts ++ ["-d '#{body}'"]
      else
        curl_parts
      end

    curl_line = Enum.join(curl_parts, " \\\n  ")

    # Generate ref extraction if this command produces refs
    ref_extraction = generate_ref_extraction(command, index)

    """
    #{var_name}=$(#{curl_line})
    echo "$#{var_name}"#{ref_extraction}
    """
  end

  # ============================================================================
  # Ref Handling
  # ============================================================================

  defp resolve_path_with_refs(%HTTPSpec{path: path, path_params: params}, _index) do
    Enum.reduce(params, path, fn {key, value}, acc ->
      resolved = resolve_value_for_bash(value)
      String.replace(acc, ":#{key}", resolved)
    end)
  end

  defp resolve_value_for_bash(%Ref{label: label}), do: "$REF_#{sanitize_label(label)}"
  defp resolve_value_for_bash(value), do: to_string(value)

  defp resolve_body_with_refs(body, command, _index) do
    # Resolve refs in the body
    resolved =
      body
      |> Enum.map(fn {key, value} ->
        resolved_value = get_command_field_value(command, key, value)
        {key, format_json_value(resolved_value)}
      end)
      |> Enum.into(%{})

    # Convert to JSON, handling ref placeholders
    json = Jason.encode!(resolved)

    # Replace ref placeholders with bash variable references
    Regex.replace(~r/"__REF_(\d+)__"/, json, fn _, idx ->
      "$REF_#{idx}"
    end)
  end

  defp get_command_field_value(command, key, default) do
    Map.get(command, key, default)
  end

  defp format_json_value(%Ref{label: label}), do: "__REF_#{sanitize_label(label)}__"
  defp format_json_value(value) when is_atom(value), do: to_string(value)
  defp format_json_value(value), do: value

  defp generate_ref_extraction(command, index) do
    # Check if this command likely produces a ref (by looking for id/ref fields)
    cmd_name = Common.command_name(command)
    label = generate_ref_label(cmd_name, index)

    if String.starts_with?(cmd_name, "Create") or String.contains?(cmd_name, "Register") do
      """

      REF_#{label}=$(echo "$RESP#{index + 1}" | jq -r '.data.id // .id // empty')
      if [ -n "$REF_#{label}" ]; then
        echo "  -> Bound ref #{label}: $REF_#{label}"
      fi
      """
    else
      ""
    end
  end

  defp generate_ref_label(cmd_name, index) do
    # Generate a label like "account_0", "booking_1" based on command name
    base =
      cmd_name
      |> String.replace(~r/^(Create|Register)/, "")
      |> Macro.underscore()
      |> String.trim("_")

    if base == "", do: "ref_#{index}", else: "#{base}_#{index}"
  end

  defp sanitize_label(nil), do: "unknown"

  defp sanitize_label(label) when is_binary(label) do
    label
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.downcase()
  end

  defp sanitize_label(label), do: sanitize_label(to_string(label))

  defp generate_footer(metadata) do
    """

    echo ""
    echo "=== Reproduction Complete ==="
    echo "Seed: #{metadata.seed}"
    """
  end
end
