defmodule PropertyDamage.Export.Script.Python do
  @moduledoc false

  alias PropertyDamage.Export.{Common, HTTPSpec}
  alias PropertyDamage.{FailureReport, Placeholder}

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

    # DR-021 placeholder wiring (see Export.Common).
    var_map = Common.placeholder_var_map(commands)
    extractions = Common.producer_extractions(commands)

    [
      generate_shebang(),
      generate_docstring(metadata, report),
      generate_imports(),
      generate_setup(env_var, base_url),
      generate_steps(report, adapter, verbose, var_map, extractions),
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

  defp generate_steps(report, adapter, verbose, var_map, extractions) do
    report
    |> FailureReport.steps()
    |> Enum.map_join("\n", fn step ->
      generate_step(
        step.command,
        step.flattened_index,
        adapter,
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

    req_code = generate_requests_code(command, http_spec, index, var_map, extractions)

    header <> label_comment <> comment <> req_code
  end

  defp generate_requests_code(command, nil, _index, _var_map, _extractions) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    print("Skipping #{cmd_name} - no HTTP mapping available")
    """
  end

  defp generate_requests_code(command, %HTTPSpec{} = spec, index, var_map, extractions) do
    var_name = "resp#{index + 1}"
    method = spec.method
    path = generate_path_code(spec, index, var_map)

    # Build the requests call
    req_call = build_requests_call(method, path, spec, command, index, var_map)

    # Extract any external values this command produces (DR-021).
    ref_extraction = generate_placeholder_extraction(index, extractions, var_name)

    """
    #{var_name} = #{req_call}
    print(f"Response: {#{var_name}.json()}")#{ref_extraction}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(%HTTPSpec{path: path, path_params: params}, _index, var_map) do
    if map_size(params) == 0 do
      inspect(path)
    else
      # Build path with f-string interpolation for refs
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = generate_value_interpolation(value, var_map)
          String.replace(acc, ":#{key}", "{#{replacement}}")
        end)

      ~s(f"#{resolved_path}")
    end
  end

  # Single-quoted dict key so it nests safely inside an f-string.
  defp generate_value_interpolation(%Placeholder{} = ph, var_map) do
    "refs['#{Map.fetch!(var_map, ph.id)}']"
  end

  defp generate_value_interpolation(value, _var_map) when is_binary(value) do
    inspect(value)
  end

  defp generate_value_interpolation(value, _var_map) do
    to_string(value)
  end

  defp build_requests_call(method, path, spec, command, index, var_map) do
    method_str = to_string(method)

    args = ["f\"{base_url}\" + #{path}"]

    # Add json body if present
    args =
      if HTTPSpec.has_body?(spec) do
        body = generate_body_dict(spec.body, command, index, var_map)
        args ++ ["json=#{body}"]
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

  defp generate_body_dict(body, command, index, var_map) do
    fields =
      body
      |> Enum.map_join(", ", fn {key, _default} ->
        value = Map.get(command, key)
        formatted = format_body_value(value, index, var_map)
        ~s("#{key}": #{formatted})
      end)

    "{#{fields}}"
  end

  defp format_body_value(%Placeholder{} = ph, _cmd_index, var_map) do
    ~s(refs["#{Map.fetch!(var_map, ph.id)}"])
  end

  # Booleans and nil must precede the is_atom clause: they are atoms in
  # Elixir but must render as Python literals, not strings
  defp format_body_value(value, _cmd_index, _var_map) when is_boolean(value) do
    if value, do: "True", else: "False"
  end

  defp format_body_value(nil, _cmd_index, _var_map), do: "None"

  defp format_body_value(value, _cmd_index, _var_map) when is_atom(value) do
    inspect(to_string(value))
  end

  defp format_body_value(value, _cmd_index, _var_map) when is_binary(value) do
    inspect(value)
  end

  defp format_body_value(value, _cmd_index, _var_map) when is_number(value) do
    to_string(value)
  end

  # Recurse into collections so a Placeholder nested in a list/map is
  # rendered as a refs[...] lookup (Jason.encode!/1 would raise on the struct).
  defp format_body_value(value, cmd_index, var_map) when is_list(value) do
    items = Enum.map_join(value, ", ", &format_body_value(&1, cmd_index, var_map))
    "[#{items}]"
  end

  defp format_body_value(value, cmd_index, var_map) when is_map(value) do
    items =
      Enum.map_join(value, ", ", fn {k, v} ->
        ~s(#{inspect(to_string(k))}: #{format_body_value(v, cmd_index, var_map)})
      end)

    "{#{items}}"
  end

  defp format_body_value(value, _cmd_index, _var_map) do
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
  defp generate_placeholder_extraction(index, extractions, resp_var) do
    case Map.get(extractions, index, []) do
      [] ->
        ""

      bindings ->
        lines =
          Enum.map_join(bindings, "\n", fn {ph, var} ->
            ~s|refs["#{var}"] = #{resp_var}.json()#{py_path(ph.path)}| <>
              "\n" <>
              ~s|print(f"  -> bound #{var}: {refs['#{var}']}")|
          end)

        "\n" <> lines
    end
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
