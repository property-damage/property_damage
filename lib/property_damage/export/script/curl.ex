defmodule PropertyDamage.Export.Script.Curl do
  @moduledoc false

  alias PropertyDamage.Export.{Common, HTTPSpec, StepPlan}
  alias PropertyDamage.FailureReport

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
    steps = StepPlan.build(report, adapter)

    [
      generate_shebang(),
      generate_header(metadata, report),
      generate_setup(env_var, base_url),
      generate_steps(steps, env_var, verbose),
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

  defp generate_steps(steps, env_var, verbose) do
    Enum.map_join(steps, "\n", &generate_step(&1, env_var, verbose))
  end

  defp generate_step(%StepPlan.Step{} = step, env_var, verbose) do
    step_num = step.flattened_index + 1
    cmd_name = Common.command_name(step.command)

    failure_marker = if step.failed?, do: " (FAILURE POINT)", else: ""
    label_comment = if is_binary(step.label), do: "# #{step.label}\n", else: ""

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
        "# Command: #{Common.command_to_comment(step.command)}\n"
      else
        ""
      end

    header <> label_comment <> comment <> generate_curl_command(step, env_var)
  end

  defp generate_curl_command(%StepPlan.Step{http_spec: nil} = step, _env_var) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(step.command)
    var_name = "RESP#{step.flattened_index + 1}"

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    #{var_name}="<no HTTPSpec available for #{cmd_name}>"
    echo "Skipping #{cmd_name} - no HTTP mapping available"
    """
  end

  defp generate_curl_command(%StepPlan.Step{http_spec: %HTTPSpec{} = spec} = step, env_var) do
    var_name = "RESP#{step.flattened_index + 1}"
    method = HTTPSpec.method_string(spec)
    path = resolve_path(spec.path, step.resolved_path_params)
    query = resolve_query(step.resolved_query_params)

    curl_parts = [
      "curl -s",
      "-X #{method}",
      "\"$#{env_var}#{path}#{query}\""
    ]

    # Add headers
    curl_parts = curl_parts ++ ["-H \"Content-Type: application/json\""]

    curl_parts =
      Enum.reduce(spec.headers, curl_parts, fn {name, value}, acc ->
        acc ++ ["-H \"#{name}: #{value}\""]
      end)

    # Add body if present
    curl_parts =
      if step.resolved_body do
        curl_parts ++ ["-d \"#{resolve_body_json(step.resolved_body)}\""]
      else
        curl_parts
      end

    curl_line = Enum.join(curl_parts, " \\\n  ")

    # Extract any external values this command produces (DR-021).
    extraction = generate_placeholder_extraction(step)

    """
    #{var_name}=$(#{curl_line})
    echo "$#{var_name}"#{extraction}
    """
  end

  # ============================================================================
  # Placeholder Handling
  # ============================================================================

  defp resolve_path(path, params) do
    Enum.reduce(params, path, fn {key, value}, acc ->
      String.replace(acc, ":#{key}", resolve_value_for_bash(value))
    end)
  end

  defp resolve_value_for_bash(%StepPlan.Var{name: name}), do: "$" <> name
  defp resolve_value_for_bash(value), do: to_string(value)

  # Render the spec's query params as a `?k=v&...` suffix. Sorted for stable
  # output; values resolve like path params (`$var` for produced refs).
  defp resolve_query(params) when map_size(params) == 0, do: ""

  defp resolve_query(params) do
    "?" <>
      (params
       |> Enum.sort()
       |> Enum.map_join("&", fn {key, value} -> "#{key}=#{resolve_value_for_bash(value)}" end))
  end

  defp resolve_body_json(resolved_body) do
    json = resolved_body |> mark_refs() |> Jason.encode!()

    # The body is emitted inside `-d "..."` (double quotes) so placeholder
    # variable references expand (DR-021). Escape the literal JSON for a
    # double-quoted shell string first, so every literal byte round-trips.
    escaped =
      json
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("`", "\\`")
      |> String.replace("$", "\\$")

    # Then re-open the placeholder markers as bare `$var` references (their
    # surrounding quotes are now escaped) so the shell expands them. Markers use
    # the variable name (alphanumeric + underscore), so match that, not digits.
    Regex.replace(~r/\\"__PH_([a-z0-9_]+)__\\"/, escaped, fn _, var -> "$#{var}" end)
  end

  # Render the resolved body into a Jason-encodable structure, turning each
  # variable ref into a marker string (recursing through collections) so a
  # placeholder nested in a list/map wires up like a top-level one.
  defp mark_refs(%StepPlan.Var{name: name}), do: "__PH_#{name}__"
  defp mark_refs(value) when is_atom(value), do: to_string(value)
  defp mark_refs(value) when is_list(value), do: Enum.map(value, &mark_refs/1)
  defp mark_refs(%_{} = struct), do: struct
  defp mark_refs(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, mark_refs(v)} end)
  defp mark_refs(value), do: value

  # Emit shell that binds each external value this command produces (DR-021),
  # extracting the placeholder's path from the JSON response with jq.
  defp generate_placeholder_extraction(%StepPlan.Step{producer_bindings: []}), do: ""

  defp generate_placeholder_extraction(%StepPlan.Step{} = step) do
    resp_var = "RESP#{step.flattened_index + 1}"

    Enum.map_join(step.producer_bindings, "", fn {path, var} ->
      """

      #{var}=$(echo "$#{resp_var}" | jq -r '#{jq_path(path)} // empty')
      if [ -n "$#{var}" ]; then
        echo "  -> bound #{var}: $#{var}"
      fi
      """
    end)
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
