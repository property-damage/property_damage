defmodule PropertyDamage.Export.Script.Elixir do
  @moduledoc false

  alias PropertyDamage.Export.{Common, HTTPSpec, StepPlan}
  alias PropertyDamage.FailureReport

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
    steps = StepPlan.build(report, adapter)

    [
      generate_shebang(),
      generate_header(metadata, report),
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

        IO.puts("")
        IO.puts("=== Step #{step_num}: #{cmd_name}#{failure_marker} ===")
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

    header <> label_comment <> comment <> generate_req_code(step)
  end

  defp generate_req_code(%StepPlan.Step{http_spec: nil} = step) do
    # No HTTPSpec available, generate placeholder
    cmd_name = Common.command_name(step.command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    IO.puts("Skipping #{cmd_name} - no HTTP mapping available")
    resp#{step.flattened_index + 1} = nil
    """
  end

  defp generate_req_code(%StepPlan.Step{http_spec: %HTTPSpec{} = spec} = step) do
    var_name = "resp#{step.flattened_index + 1}"
    method = spec.method

    path =
      spec.path
      |> generate_path_code(step.resolved_path_params)
      |> append_query_code(step.resolved_query_params)

    # Build the Req call
    req_opts = build_req_opts(spec, step.resolved_body)

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
    ref_extraction = generate_placeholder_extraction(step, var_name)

    """
    #{var_name} = #{req_call}
    IO.inspect(#{var_name}.body, label: "Response")#{ref_extraction}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(path, params) do
    if map_size(params) == 0 do
      inspect(path)
    else
      # Build path with interpolation for refs
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = "\#{#{generate_value_interpolation(value)}}"
          # Match `:key` only at a token boundary so `:id` does not corrupt `:id_tx`.
          Regex.replace(~r/:#{Regex.escape(to_string(key))}(?![A-Za-z0-9_])/, acc, fn _ ->
            replacement
          end)
        end)

      ~s("#{resolved_path}")
    end
  end

  defp generate_value_interpolation(%StepPlan.Var{name: name}) do
    "refs[#{inspect(name)}]"
  end

  defp generate_value_interpolation(value) do
    inspect(value)
  end

  # Append the spec's query params as a `?k=v&...` fragment onto the path
  # string. Sorted for stable output; values interpolate like path params
  # (a produced ref renders as `refs["name"]`).
  defp append_query_code(path_code, params) when map_size(params) == 0, do: path_code

  defp append_query_code(path_code, params) do
    pairs =
      params
      |> Enum.sort()
      |> Enum.map_join("&", fn {key, value} ->
        "#{key}=\#{#{generate_value_interpolation(value)}}"
      end)

    ~s(#{path_code} <> "?#{pairs}")
  end

  defp build_req_opts(spec, resolved_body) do
    opts = []

    # Add body if present
    opts =
      if resolved_body do
        opts ++ ["json: #{generate_body_map(resolved_body)}"]
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

  defp generate_body_map(body) do
    fields =
      Enum.map_join(body, ", ", fn {key, value} -> "#{key}: #{format_body_value(value)}" end)

    "%{#{fields}}"
  end

  # A variable ref renders as a `refs[...]` lookup. Collections that contain a
  # ref are rendered element-by-element so nested placeholders resolve; those
  # without a ref fall through to `inspect/1`, preserving prior output exactly.
  defp format_body_value(%StepPlan.Var{name: name}), do: "refs[#{inspect(name)}]"

  defp format_body_value(value) when is_list(value) do
    if StepPlan.contains_var?(value) do
      "[" <> Enum.map_join(value, ", ", &format_body_value/1) <> "]"
    else
      inspect(value)
    end
  end

  defp format_body_value(value) when is_map(value) and not is_struct(value) do
    if StepPlan.contains_var?(value) do
      "%{" <> Enum.map_join(value, ", ", &format_body_pair/1) <> "}"
    else
      inspect(value)
    end
  end

  defp format_body_value(value), do: inspect(value)

  defp format_body_pair({key, value}) when is_atom(key), do: "#{key}: #{format_body_value(value)}"

  defp format_body_pair({key, value}),
    do: "#{format_body_value(key)} => #{format_body_value(value)}"

  # ============================================================================
  # Placeholder Extraction (DR-021)
  # ============================================================================

  defp generate_placeholder_extraction(%StepPlan.Step{producer_bindings: []}, _resp_var), do: ""

  defp generate_placeholder_extraction(%StepPlan.Step{} = step, resp_var) do
    lines =
      Enum.map_join(step.producer_bindings, "\n", fn {path, var} ->
        key = inspect(var)

        "refs = Map.put(refs, #{key}, get_in(#{resp_var}.body, #{ex_access(path)}))" <>
          "\n" <>
          ~s|IO.puts("  -> bound #{var}: \#{inspect(refs[#{key}])}")|
      end)

    "\n" <> lines
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

  defp generate_footer(metadata) do
    """

    IO.puts("")
    IO.puts("=== Reproduction Complete ===")
    IO.puts("Seed: #{metadata.seed}")
    """
  end
end
