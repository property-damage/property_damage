defmodule PropertyDamage.Export.Script.Curl do
  @moduledoc false

  alias PropertyDamage.Export.{Common, HTTPSpec}
  alias PropertyDamage.{FailureReport, Placeholder}

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

    # DR-021 placeholder wiring: var name per consumed external value, and the
    # values each producer command must extract from its response.
    var_map = Common.placeholder_var_map(commands)
    extractions = Common.producer_extractions(commands)

    [
      generate_shebang(),
      generate_header(metadata, report),
      generate_setup(env_var, base_url),
      generate_steps(report, adapter, env_var, verbose, var_map, extractions),
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

  defp generate_header(metadata, report) do
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
    # Run with: bash #{Common.generate_filename(report, :curl)}
    """
  end

  defp generate_setup(env_var, default_url) do
    """
    set -e  # Exit on error

    #{env_var}="${#{env_var}:-#{default_url}}"
    """
  end

  defp generate_steps(report, adapter, env_var, verbose, var_map, extractions) do
    report
    |> FailureReport.steps()
    |> Enum.map_join("\n", fn step ->
      generate_step(
        step.command,
        step.flattened_index,
        adapter,
        env_var,
        step.failed?,
        verbose,
        var_map,
        extractions,
        step.label
      )
    end)
  end

  defp generate_step(
         command,
         index,
         adapter,
         env_var,
         is_failure_point,
         verbose,
         var_map,
         extractions,
         label
       ) do
    step_num = index + 1
    cmd_name = Common.command_name(command)
    http_spec = Common.get_http_spec(command, adapter, %{})

    failure_marker = if is_failure_point, do: " (FAILURE POINT)", else: ""
    label_comment = if is_binary(label), do: "# #{label}\n", else: ""

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

    curl_cmd = generate_curl_command(command, http_spec, env_var, index, var_map, extractions)

    header <> label_comment <> comment <> curl_cmd
  end

  defp generate_curl_command(command, nil, _env_var, index, _var_map, _extractions) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(command)
    var_name = "RESP#{index + 1}"

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    #{var_name}="<no HTTPSpec available for #{cmd_name}>"
    echo "Skipping #{cmd_name} - no HTTP mapping available"
    """
  end

  defp generate_curl_command(command, %HTTPSpec{} = spec, env_var, index, var_map, extractions) do
    var_name = "RESP#{index + 1}"
    method = HTTPSpec.method_string(spec)
    path = resolve_path_with_refs(spec, var_map)

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
        body = resolve_body_with_refs(spec.body, command, var_map)
        curl_parts ++ ["-d '#{body}'"]
      else
        curl_parts
      end

    curl_line = Enum.join(curl_parts, " \\\n  ")

    # Extract any external values this command produces (DR-021).
    extraction = generate_placeholder_extraction(index, extractions)

    """
    #{var_name}=$(#{curl_line})
    echo "$#{var_name}"#{extraction}
    """
  end

  # ============================================================================
  # Placeholder Handling
  # ============================================================================

  defp resolve_path_with_refs(%HTTPSpec{path: path, path_params: params}, var_map) do
    Enum.reduce(params, path, fn {key, value}, acc ->
      resolved = resolve_value_for_bash(value, var_map)
      String.replace(acc, ":#{key}", resolved)
    end)
  end

  defp resolve_value_for_bash(%Placeholder{} = ph, var_map) do
    "$" <> Map.fetch!(var_map, ph.id)
  end

  defp resolve_value_for_bash(value, _var_map), do: to_string(value)

  defp resolve_body_with_refs(body, command, var_map) do
    resolved =
      body
      |> Enum.map(fn {key, value} ->
        resolved_value = Map.get(command, key, value)
        {key, format_json_value(resolved_value, var_map)}
      end)
      |> Enum.into(%{})

    json = Jason.encode!(resolved)

    # Replace placeholder markers with bash variable references. Markers use the
    # variable name (alphanumeric + underscore), so match that, not digits.
    json
    |> then(&Regex.replace(~r/"__PH_([a-z0-9_]+)__"/, &1, fn _, var -> "$#{var}" end))
  end

  defp format_json_value(%Placeholder{} = ph, var_map), do: "__PH_#{Map.fetch!(var_map, ph.id)}__"
  defp format_json_value(value, _var_map) when is_atom(value), do: to_string(value)
  defp format_json_value(value, _var_map), do: value

  # Emit shell that binds each external value this command produces (DR-021),
  # extracting the placeholder's path from the JSON response with jq.
  defp generate_placeholder_extraction(index, extractions) do
    case Map.get(extractions, index, []) do
      [] ->
        ""

      bindings ->
        Enum.map_join(bindings, "", fn {ph, var} ->
          """

          #{var}=$(echo "$RESP#{index + 1}" | jq -r '#{jq_path(ph.path)} // empty')
          if [ -n "$#{var}" ]; then
            echo "  -> bound #{var}: $#{var}"
          fi
          """
        end)
    end
  end

  defp jq_path(path) do
    Enum.map_join(path, "", fn
      i when is_integer(i) -> "[#{i}]"
      key -> ".#{key}"
    end)
  end

  defp generate_footer(metadata) do
    """

    echo ""
    echo "=== Reproduction Complete ==="
    echo "Seed: #{metadata.seed}"
    """
  end
end
