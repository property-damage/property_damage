defmodule PropertyDamage.Export.Script.Elixir do
  @moduledoc """
  Generates Elixir scripts with Req for failure reproduction.

  The generated scripts:
  - Use Mix.install for dependencies (Req, Jason)
  - Support environment variable for base URL
  - Track refs using a map
  - Are self-contained and runnable with `elixir script.exs`
  """

  alias PropertyDamage.{FailureReport, Ref}
  alias PropertyDamage.Export.{Common, HTTPSpec}

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

    [
      generate_shebang(),
      generate_header(metadata),
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
    "#!/usr/bin/env elixir"
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
    # Run with: elixir #{Common.generate_filename(%FailureReport{seed: metadata.seed}, :elixir)}
    """
  end

  defp generate_setup(env_var, default_url) do
    """
    Mix.install([{:req, "~> 0.5"}, {:jason, "~> 1.4"}])

    base_url = System.get_env("#{env_var}", "#{default_url}")
    refs = %{}
    """
  end

  defp generate_steps(commands, report, adapter, verbose) do
    commands
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, idx} ->
      is_failure_point = idx == report.failed_at_index
      generate_step(cmd, idx, adapter, is_failure_point, verbose)
    end)
  end

  defp generate_step(command, index, adapter, is_failure_point, verbose) do
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

    req_code = generate_req_code(command, http_spec, index)

    header <> comment <> req_code
  end

  defp generate_req_code(command, nil, index) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    IO.puts("Skipping #{cmd_name} - no HTTP mapping available")
    resp#{index + 1} = nil
    """
  end

  defp generate_req_code(command, %HTTPSpec{} = spec, index) do
    var_name = "resp#{index + 1}"
    method = spec.method
    path = generate_path_code(spec, index)

    # Build the Req call
    req_opts = build_req_opts(spec, command, index)

    req_call =
      case method do
        :get -> "Req.get!(base_url <> #{path}#{req_opts})"
        :post -> "Req.post!(base_url <> #{path}#{req_opts})"
        :put -> "Req.put!(base_url <> #{path}#{req_opts})"
        :patch -> "Req.patch!(base_url <> #{path}#{req_opts})"
        :delete -> "Req.delete!(base_url <> #{path}#{req_opts})"
        _ -> "Req.request!(method: :#{method}, url: base_url <> #{path}#{req_opts})"
      end

    # Generate ref extraction if this command likely produces refs
    ref_extraction = generate_ref_extraction(command, index, var_name)

    """
    #{var_name} = #{req_call}
    IO.inspect(#{var_name}.body, label: "Response")#{ref_extraction}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(%HTTPSpec{path: path, path_params: params}, index) do
    if map_size(params) == 0 do
      inspect(path)
    else
      # Build path with interpolation for refs
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = generate_value_interpolation(value, index)
          String.replace(acc, ":#{key}", "\#{#{replacement}}")
        end)

      ~s("#{resolved_path}")
    end
  end

  defp generate_value_interpolation(%Ref{label: label}, _cmd_index) do
    "refs[#{inspect(sanitize_label(label))}]"
  end

  defp generate_value_interpolation(value, _cmd_index) do
    inspect(value)
  end

  defp build_req_opts(spec, command, index) do
    opts = []

    # Add body if present
    opts =
      if HTTPSpec.has_body?(spec) do
        body = generate_body_map(spec.body, command, index)
        opts ++ ["json: #{body}"]
      else
        opts
      end

    # Add headers if present
    opts =
      if length(spec.headers) > 0 do
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

  defp generate_body_map(body, command, index) do
    fields =
      body
      |> Enum.map_join(", ", fn {key, _default} ->
        value = Map.get(command, key)
        formatted = format_body_value(value, index)
        "#{key}: #{formatted}"
      end)

    "%{#{fields}}"
  end

  defp format_body_value(%Ref{label: label}, _cmd_index) do
    "refs[#{inspect(sanitize_label(label))}]"
  end

  defp format_body_value(value, _cmd_index) when is_atom(value) do
    inspect(value)
  end

  defp format_body_value(value, _cmd_index) do
    inspect(value)
  end

  # ============================================================================
  # Ref Extraction
  # ============================================================================

  defp generate_ref_extraction(command, index, resp_var) do
    cmd_name = Common.command_name(command)
    label = generate_ref_label(cmd_name, index)
    label_str = inspect(label)

    if String.starts_with?(cmd_name, "Create") or String.contains?(cmd_name, "Register") do
      """


      # Extract ref from response
      refs = case #{resp_var}.body do
        %{"data" => %{"id" => id}} -> Map.put(refs, #{label_str}, id)
        %{"id" => id} -> Map.put(refs, #{label_str}, id)
        _ -> refs
      end
      if Map.has_key?(refs, #{label_str}), do: IO.puts("  -> Bound ref #{label}: \#{refs[#{label_str}]}")
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

    IO.puts("")
    IO.puts("=== Reproduction Complete ===")
    IO.puts("Seed: #{metadata.seed}")
    """
  end
end
