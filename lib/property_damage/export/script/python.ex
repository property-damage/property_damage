defmodule PropertyDamage.Export.Script.Python do
  @moduledoc false

  alias PropertyDamage.Export.{Common, HTTPSpec, StepPlan}
  alias PropertyDamage.FailureReport

  @doc """
  Generates a Python script from a failure report.

  ## Options

  - `:base_url` - Base URL for HTTP calls (default: "http://localhost:4000")
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
      generate_docstring(metadata, report),
      generate_imports(),
      generate_setup(env_var, base_url),
      generate_steps(steps, verbose),
      generate_footer(metadata)
    ]
    |> Enum.join("\n")
  end

  # ============================================================================
  # Script Parts
  # ============================================================================

  defp generate_shebang do
    "#!/usr/bin/env python3"
  end

  defp generate_docstring(metadata, report) do
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

    ~s("""
Failure Reproduction Script
Generated: #{timestamp}
Failure: #{failure_desc}
Seed: #{metadata.seed}

Prerequisites: pip install requests
Run with: python #{Common.generate_filename(report, :python)}
""")
  end

  defp generate_imports do
    """
    import os
    import json
    import requests
    """
  end

  defp generate_setup(env_var, default_url) do
    """
    base_url = os.environ.get("#{env_var}", "#{default_url}")
    refs = {}
    """
  end

  defp generate_steps(steps, verbose) do
    Enum.map_join(steps, "\n", &generate_step(&1, verbose))
  end

  defp generate_step(%StepPlan.Step{} = step, verbose) do
    step_num = step.flattened_index + 1
    cmd_name = Common.command_name(step.command)

    failure_marker = if step.failed?, do: " (FAILURE POINT)", else: ""
    label_comment = if is_binary(step.label), do: "# #{step.label}\n", else: ""

    header =
      if verbose do
        """

        print()
        print(f"=== Step #{step_num}: #{cmd_name}#{failure_marker} ===")
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

    header <> label_comment <> comment <> generate_requests_code(step)
  end

  defp generate_requests_code(%StepPlan.Step{http_spec: nil} = step) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(step.command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    print("Skipping #{cmd_name} - no HTTP mapping available")
    """
  end

  defp generate_requests_code(%StepPlan.Step{http_spec: %HTTPSpec{} = spec} = step) do
    var_name = "resp#{step.flattened_index + 1}"

    path =
      spec.path
      |> generate_path_code(step.resolved_path_params)
      |> append_query_code(step.resolved_query_params)

    # Build the requests call
    req_call = build_requests_call(spec.method, path, spec, step.resolved_body)

    # Extract any external values this command produces (DR-021).
    ref_extraction = generate_placeholder_extraction(step, var_name)

    """
    #{var_name} = #{req_call}
    print(f"Response: {#{var_name}.json()}")#{ref_extraction}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(path, params) do
    if map_size(params) == 0 do
      inspect(path)
    else
      # Build path with f-string interpolation for refs
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = "{#{generate_value_interpolation(value)}}"
          # Match `:key` only at a token boundary so `:id` does not corrupt `:id_tx`.
          Regex.replace(~r/:#{Regex.escape(to_string(key))}(?![A-Za-z0-9_])/, acc, fn _ ->
            replacement
          end)
        end)

      ~s(f"#{resolved_path}")
    end
  end

  # Append the spec's query params as an f-string `?k=v&...` fragment onto the
  # path expression. Sorted for stable output; values interpolate like path
  # params (a produced ref renders as `refs['name']`).
  defp append_query_code(path_code, params) when map_size(params) == 0, do: path_code

  defp append_query_code(path_code, params) do
    pairs =
      params
      |> Enum.sort()
      |> Enum.map_join("&", fn {key, value} ->
        "#{key}={#{generate_value_interpolation(value)}}"
      end)

    ~s(#{path_code} + f"?#{pairs}")
  end

  # Single-quoted dict key so it nests safely inside an f-string.
  defp generate_value_interpolation(%StepPlan.Var{name: name}) do
    "refs['#{name}']"
  end

  defp generate_value_interpolation(value) when is_binary(value) do
    inspect(value)
  end

  defp generate_value_interpolation(value) do
    to_string(value)
  end

  defp build_requests_call(method, path, spec, resolved_body) do
    method_str = to_string(method)

    args = ["f\"{base_url}\" + #{path}"]

    # Add json body if present
    args =
      if resolved_body do
        args ++ ["json=#{generate_body_dict(resolved_body)}"]
      else
        args
      end

    # Add headers if present
    args =
      if spec.headers != [] do
        headers = generate_headers_dict(spec.headers)
        args ++ ["headers=#{headers}"]
      else
        args
      end

    "requests.#{method_str}(#{Enum.join(args, ", ")})"
  end

  defp generate_body_dict(body) do
    fields =
      Enum.map_join(body, ", ", fn {key, value} ->
        ~s("#{key}": #{format_body_value(value)})
      end)

    "{#{fields}}"
  end

  defp format_body_value(%StepPlan.Var{name: name}) do
    ~s(refs["#{name}"])
  end

  # Booleans and nil must precede the is_atom clause: they are atoms in
  # Elixir but must render as Python literals, not strings
  defp format_body_value(value) when is_boolean(value) do
    if value, do: "True", else: "False"
  end

  defp format_body_value(nil), do: "None"

  defp format_body_value(value) when is_atom(value) do
    inspect(to_string(value))
  end

  defp format_body_value(value) when is_binary(value) do
    inspect(value)
  end

  defp format_body_value(value) when is_number(value) do
    to_string(value)
  end

  # Recurse into collections so a Var nested in a list/map is rendered as a
  # refs[...] lookup (Jason.encode!/1 would raise on the struct).
  defp format_body_value(value) when is_list(value) do
    "[#{Enum.map_join(value, ", ", &format_body_value/1)}]"
  end

  defp format_body_value(value) when is_map(value) do
    items =
      Enum.map_join(value, ", ", fn {k, v} ->
        ~s(#{inspect(to_string(k))}: #{format_body_value(v)})
      end)

    "{#{items}}"
  end

  defp format_body_value(value) do
    inspect(value)
  end

  defp generate_headers_dict(headers) do
    fields =
      headers
      |> Enum.map_join(", ", fn {name, value} -> ~s("#{name}": "#{value}") end)

    "{#{fields}}"
  end

  # ============================================================================
  # Placeholder Extraction (DR-021)
  # ============================================================================

  # Bind each external value this command produces from its JSON response.
  defp generate_placeholder_extraction(%StepPlan.Step{producer_bindings: []}, _resp_var), do: ""

  defp generate_placeholder_extraction(%StepPlan.Step{} = step, resp_var) do
    lines =
      Enum.map_join(step.producer_bindings, "\n", fn {path, var} ->
        ~s|refs["#{var}"] = #{resp_var}.json()#{py_path(path)}| <>
          "\n" <>
          ~s|print(f"  -> bound #{var}: {refs['#{var}']}")|
      end)

    "\n" <> lines
  end

  defp py_path(path) do
    Enum.map_join(path, "", fn
      i when is_integer(i) -> "[#{i}]"
      key -> ~s(["#{key}"])
    end)
  end

  defp generate_footer(metadata) do
    """

    print()
    print("=== Reproduction Complete ===")
    print(f"Seed: #{metadata.seed}")
    """
  end
end
