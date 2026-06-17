defmodule PropertyDamage.Export.Script.Elixir do
  @moduledoc """
  Generates Elixir scripts with Req for failure reproduction.

  The generated scripts:
  - Use Mix.install for dependencies (Req, Jason)
  - Support environment variable for base URL
  - Track refs using a map
  - Are self-contained and runnable with `elixir script.exs`
  """

  alias PropertyDamage.Export.{Common, HTTPSpec}
  alias PropertyDamage.{FailureReport, Placeholder, Ref}

  @doc """
  Generates an Elixir script from a failure report.

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

    var_map = Common.placeholder_var_map(commands)
    extractions = Common.producer_extractions(commands)

    [
      generate_shebang(),
      generate_header(metadata, report),
      generate_setup(env_var, base_url),
      generate_steps(commands, report, adapter, verbose, var_map, extractions),
      generate_footer(metadata)
    ]
    |> Enum.join("\n")
  end

  # ============================================================================
  # Script Parts
  # ============================================================================

  defp generate_shebang do
    "#!/usr/bin/env elixir"
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
    # Run with: elixir #{Common.generate_filename(report, :elixir)}
    """
  end

  defp generate_setup(env_var, default_url) do
    """
    Mix.install([{:req, "~> 0.5"}, {:jason, "~> 1.4"}])

    base_url = System.get_env("#{env_var}", "#{default_url}")
    refs = %{}
    """
  end

  defp generate_steps(commands, report, adapter, verbose, var_map, extractions) do
    commands
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, idx} ->
      is_failure_point = idx == report.failed_at_index
      generate_step(cmd, idx, adapter, is_failure_point, verbose, var_map, extractions)
    end)
  end

  defp generate_step(command, index, adapter, is_failure_point, verbose, var_map, extractions) do
    step_num = index + 1
    cmd_name = Common.command_name(command)
    http_spec = Common.get_http_spec(command, adapter, %{})

    failure_marker = if is_failure_point, do: " (FAILURE POINT)", else: ""

    header =
      if verbose do
        """

        IO.puts("")
        IO.puts("=== Step #{step_num}: #{cmd_name}#{failure_marker} ===")
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

    req_code = generate_req_code(command, http_spec, index, var_map, extractions)

    header <> comment <> req_code
  end

  defp generate_req_code(command, nil, index, _var_map, _extractions) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    IO.puts("Skipping #{cmd_name} - no HTTP mapping available")
    resp#{index + 1} = nil
    """
  end

  defp generate_req_code(command, %HTTPSpec{} = spec, index, var_map, extractions) do
    var_name = "resp#{index + 1}"
    method = spec.method
    path = generate_path_code(spec, index, var_map)

    # Build the Req call
    req_opts = build_req_opts(spec, command, index, var_map)

    req_call =
      case method do
        :get -> "Req.get!(base_url <> #{path}#{req_opts})"
        :post -> "Req.post!(base_url <> #{path}#{req_opts})"
        :put -> "Req.put!(base_url <> #{path}#{req_opts})"
        :patch -> "Req.patch!(base_url <> #{path}#{req_opts})"
        :delete -> "Req.delete!(base_url <> #{path}#{req_opts})"
        _ -> "Req.request!(method: :#{method}, url: base_url <> #{path}#{req_opts})"
      end

    # Extract any external values this command produces (DR-021).
    ref_extraction = generate_placeholder_extraction(index, extractions, var_name)

    """
    #{var_name} = #{req_call}
    IO.inspect(#{var_name}.body, label: "Response")#{ref_extraction}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(%HTTPSpec{path: path, path_params: params}, _index, var_map) do
    if map_size(params) == 0 do
      inspect(path)
    else
      # Build path with interpolation for refs
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = generate_value_interpolation(value, var_map)
          String.replace(acc, ":#{key}", "\#{#{replacement}}")
        end)

      ~s("#{resolved_path}")
    end
  end

  defp generate_value_interpolation(%Placeholder{} = ph, var_map) do
    "refs[#{inspect(Map.fetch!(var_map, ph.id))}]"
  end

  defp generate_value_interpolation(%Ref{label: label}, _var_map) do
    "refs[#{inspect(sanitize_label(label))}]"
  end

  defp generate_value_interpolation(value, _var_map) do
    inspect(value)
  end

  defp build_req_opts(spec, command, index, var_map) do
    opts = []

    # Add body if present
    opts =
      if HTTPSpec.has_body?(spec) do
        body = generate_body_map(spec.body, command, index, var_map)
        opts ++ ["json: #{body}"]
      else
        opts
      end

    # Add headers if present
    opts =
      if spec.headers != [] do
        headers = inspect(spec.headers)
        opts ++ ["headers: #{headers}"]
      else
        opts
      end

    if opts == [] do
      ""
    else
      ", " <> Enum.join(opts, ", ")
    end
  end

  defp generate_body_map(body, command, index, var_map) do
    fields =
      body
      |> Enum.map_join(", ", fn {key, _default} ->
        value = Map.get(command, key)
        formatted = format_body_value(value, index, var_map)
        "#{key}: #{formatted}"
      end)

    "%{#{fields}}"
  end

  defp format_body_value(%Placeholder{} = ph, _cmd_index, var_map) do
    "refs[#{inspect(Map.fetch!(var_map, ph.id))}]"
  end

  defp format_body_value(%Ref{label: label}, _cmd_index, _var_map) do
    "refs[#{inspect(sanitize_label(label))}]"
  end

  defp format_body_value(value, _cmd_index, _var_map) do
    inspect(value)
  end

  # ============================================================================
  # Placeholder Extraction (DR-021)
  # ============================================================================

  defp generate_placeholder_extraction(index, extractions, resp_var) do
    case Map.get(extractions, index, []) do
      [] ->
        ""

      bindings ->
        lines =
          Enum.map_join(bindings, "\n", fn {ph, var} ->
            key = inspect(var)

            "refs = Map.put(refs, #{key}, get_in(#{resp_var}.body, #{ex_access(ph.path)}))" <>
              "\n" <>
              ~s|IO.puts("  -> bound #{var}: \#{inspect(refs[#{key}])}")|
          end)

        "\n" <> lines
    end
  end

  # Access path for get_in/2 over a JSON-decoded (string-keyed) body.
  defp ex_access(path) do
    inner =
      Enum.map_join(path, ", ", fn
        i when is_integer(i) -> "Access.at(#{i})"
        key -> inspect(to_string(key))
      end)

    "[#{inner}]"
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

    IO.puts("")
    IO.puts("=== Reproduction Complete ===")
    IO.puts("Seed: #{metadata.seed}")
    """
  end
end
