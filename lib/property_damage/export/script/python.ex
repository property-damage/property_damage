defmodule PropertyDamage.Export.Script.Python do
  @moduledoc """
  Generates Python scripts with requests for failure reproduction.

  The generated scripts:
  - Use the requests library for HTTP calls
  - Support environment variable for base URL
  - Track refs using a dictionary
  - Are self-contained and runnable with `python script.py`
  """

  alias PropertyDamage.{FailureReport, Ref}
  alias PropertyDamage.Export.{Common, HTTPSpec}

  @doc """
  Generates a Python script from a failure report.

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
      generate_docstring(metadata),
      generate_imports(),
      generate_setup(env_var, base_url),
      generate_steps(commands, report, adapter, verbose),
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

  defp generate_docstring(metadata) do
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
Run with: python #{Common.generate_filename(%FailureReport{seed: metadata.seed}, :python)}
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

  defp generate_steps(commands, report, adapter, verbose) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      is_failure_point = idx == report.failed_at_index
      generate_step(cmd, idx, adapter, is_failure_point, verbose)
    end)
    |> Enum.join("\n")
  end

  defp generate_step(command, index, adapter, is_failure_point, verbose) do
    step_num = index + 1
    cmd_name = Common.command_name(command)
    http_spec = Common.get_http_spec(command, adapter, %{})

    failure_marker = if is_failure_point, do: " (FAILURE POINT)", else: ""

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
        "# Command: #{Common.command_to_comment(command)}\n"
      else
        ""
      end

    req_code = generate_requests_code(command, http_spec, index)

    header <> comment <> req_code
  end

  defp generate_requests_code(command, nil, _index) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    print("Skipping #{cmd_name} - no HTTP mapping available")
    """
  end

  defp generate_requests_code(command, %HTTPSpec{} = spec, index) do
    var_name = "resp#{index + 1}"
    method = spec.method
    path = generate_path_code(spec, index)

    # Build the requests call
    req_call = build_requests_call(method, path, spec, command, index)

    # Generate ref extraction if this command likely produces refs
    ref_extraction = generate_ref_extraction(command, index, var_name)

    """
    #{var_name} = #{req_call}
    print(f"Response: {#{var_name}.json()}")#{ref_extraction}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(%HTTPSpec{path: path, path_params: params}, index) do
    if map_size(params) == 0 do
      inspect(path)
    else
      # Build path with f-string interpolation for refs
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = generate_value_interpolation(value, index)
          String.replace(acc, ":#{key}", "{#{replacement}}")
        end)

      ~s(f"#{resolved_path}")
    end
  end

  defp generate_value_interpolation(%Ref{label: label}, _cmd_index) do
    "refs[#{inspect(sanitize_label(label))}]"
  end

  defp generate_value_interpolation(value, _cmd_index) when is_binary(value) do
    inspect(value)
  end

  defp generate_value_interpolation(value, _cmd_index) do
    to_string(value)
  end

  defp build_requests_call(method, path, spec, command, index) do
    method_str = to_string(method)

    args = ["f\"{base_url}\" + #{path}"]

    # Add json body if present
    args =
      if HTTPSpec.has_body?(spec) do
        body = generate_body_dict(spec.body, command, index)
        args ++ ["json=#{body}"]
      else
        args
      end

    # Add headers if present
    args =
      if length(spec.headers) > 0 do
        headers = generate_headers_dict(spec.headers)
        args ++ ["headers=#{headers}"]
      else
        args
      end

    "requests.#{method_str}(#{Enum.join(args, ", ")})"
  end

  defp generate_body_dict(body, command, index) do
    fields =
      body
      |> Enum.map(fn {key, _default} ->
        value = Map.get(command, key)
        formatted = format_body_value(value, index)
        ~s("#{key}": #{formatted})
      end)
      |> Enum.join(", ")

    "{#{fields}}"
  end

  defp format_body_value(%Ref{label: label}, _cmd_index) do
    "refs[#{inspect(sanitize_label(label))}]"
  end

  defp format_body_value(value, _cmd_index) when is_atom(value) do
    inspect(to_string(value))
  end

  defp format_body_value(value, _cmd_index) when is_binary(value) do
    inspect(value)
  end

  defp format_body_value(value, _cmd_index) when is_number(value) do
    to_string(value)
  end

  defp format_body_value(value, _cmd_index) when is_boolean(value) do
    if value, do: "True", else: "False"
  end

  defp format_body_value(value, _cmd_index) when is_list(value) do
    Jason.encode!(value)
  end

  defp format_body_value(value, _cmd_index) when is_map(value) do
    Jason.encode!(value)
  end

  defp format_body_value(nil, _cmd_index), do: "None"

  defp format_body_value(value, _cmd_index) do
    inspect(value)
  end

  defp generate_headers_dict(headers) do
    fields =
      headers
      |> Enum.map(fn {name, value} -> ~s("#{name}": "#{value}") end)
      |> Enum.join(", ")

    "{#{fields}}"
  end

  # ============================================================================
  # Ref Extraction
  # ============================================================================

  defp generate_ref_extraction(command, index, resp_var) do
    cmd_name = Common.command_name(command)
    label = generate_ref_label(cmd_name, index)

    if String.starts_with?(cmd_name, "Create") or String.contains?(cmd_name, "Register") do
      """

      # Extract ref from response
      data = #{resp_var}.json()
      if "data" in data and "id" in data["data"]:
          refs["#{label}"] = data["data"]["id"]
          print(f"  -> Bound ref #{label}: {refs['#{label}']}")
      elif "id" in data:
          refs["#{label}"] = data["id"]
          print(f"  -> Bound ref #{label}: {refs['#{label}']}")
      """
    else
      ""
    end
  end

  defp generate_ref_label(cmd_name, index) do
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

    print()
    print("=== Reproduction Complete ===")
    print(f"Seed: #{metadata.seed}")
    """
  end
end
