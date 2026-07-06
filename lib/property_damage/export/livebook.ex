defmodule PropertyDamage.Export.LiveBook do
  @moduledoc false

  alias PropertyDamage.Export.{Common, HTTPSpec, StepPlan}
  alias PropertyDamage.FailureReport

  @doc """
  Generates a LiveBook notebook from a failure report.

  ## Options

  - `:base_url` - Base URL for HTTP calls (required)
  - `:adapter` - Adapter module for HTTPSpec (optional)
  - `:include_exploration` - Include exploration section (default: true)
  - `:include_state_tracking` - Track model state (default: true)
  - `:title` - Custom notebook title (optional)
  """
  @spec generate(FailureReport.t(), keyword()) :: String.t()
  def generate(%FailureReport{} = report, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:4000")
    adapter = Keyword.get(opts, :adapter)
    include_exploration = Keyword.get(opts, :include_exploration, true)
    include_state = Keyword.get(opts, :include_state_tracking, true)

    metadata = Common.extract_metadata(report)
    title = Keyword.get(opts, :title, generate_title(metadata))

    steps = StepPlan.build(report, adapter)

    sections = [
      generate_header(title, metadata),
      generate_setup_section(base_url, include_state),
      generate_command_sections(steps, include_state)
    ]

    sections =
      if include_exploration do
        sections ++ [generate_exploration_section(base_url)]
      else
        sections
      end

    sections
    |> List.flatten()
    |> Enum.join("\n")
  end

  # ============================================================================
  # Header
  # ============================================================================

  defp generate_header(title, metadata) do
    failure_desc =
      case metadata.check_name do
        nil -> to_string(metadata.failure_type)
        check -> "#{check} check failed"
      end

    timestamp =
      case metadata.timestamp do
        %DateTime{} = dt -> DateTime.to_date(dt) |> Date.to_string()
        _ -> Date.utc_today() |> Date.to_string()
      end

    """
    # #{title}

    **Seed**: #{metadata.seed}
    **Failure Type**: #{failure_desc}
    **Date**: #{timestamp}

    This notebook allows you to step through the command sequence that triggered a failure,
    inspect state at each step, and explore variations to understand the root cause.
    """
  end

  # ============================================================================
  # Setup Section
  # ============================================================================

  defp generate_setup_section(base_url, include_state) do
    state_init =
      if include_state do
        "\nstate = %{refs: %{}, data: %{}}"
      else
        ""
      end

    """
    ## Setup

    ```elixir
    Mix.install([{:req, "~> 0.5"}, {:jason, "~> 1.4"}])

    base_url = "#{base_url}"#{state_init}
    ```
    """
  end

  # ============================================================================
  # Command Sections
  # ============================================================================

  defp generate_command_sections(steps, include_state) do
    header = "\n## Command Sequence\n"
    sections = Enum.map(steps, &generate_command_section(&1, include_state))
    [header | sections]
  end

  defp generate_command_section(%StepPlan.Step{} = step, include_state) do
    step_num = step.flattened_index + 1
    cmd_name = Common.command_name(step.command)

    failure_marker = if step.failed?, do: " (FAILURE)", else: ""
    label_suffix = if is_binary(step.label), do: ": #{step.label}", else: ""
    warning = if step.failed?, do: "\n> ⚠️ **This command caused the failure**\n", else: ""

    code = generate_livebook_code(step, include_state)

    """
    ### Step #{step_num}: #{cmd_name}#{label_suffix}#{failure_marker}
    #{warning}
    ```elixir
    # Command: #{Common.command_to_comment(step.command)}
    #{code}
    ```
    """
  end

  defp generate_livebook_code(%StepPlan.Step{http_spec: nil} = step, _include_state) do
    cmd_name = Common.command_name(step.command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    IO.puts("No HTTP mapping available for #{cmd_name}")
    """
  end

  defp generate_livebook_code(%StepPlan.Step{http_spec: %HTTPSpec{} = spec} = step, include_state) do
    method = spec.method

    path =
      spec.path
      |> generate_path_code(step.resolved_path_params)
      |> append_query_code(step.resolved_query_params)

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

    state_update =
      if include_state do
        generate_state_update(step)
      else
        ""
      end

    failure_check =
      if step.failed? do
        """

        # Check the state at failure point
        IO.puts("\\n--- Failure Analysis ---")
        IO.inspect(state, label: "State at failure")
        """
      else
        ""
      end

    """
    resp = #{req_call}
    IO.inspect(resp.body, label: "Response")
    #{state_update}#{failure_check}
    """
  end

  # ============================================================================
  # Path and Body Generation
  # ============================================================================

  defp generate_path_code(path, params) do
    if map_size(params) == 0 do
      inspect(path)
    else
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
    "state.refs[#{inspect(name)}]"
  end

  defp generate_value_interpolation(value) do
    inspect(value)
  end

  # Append the spec's query params as a `?k=v&...` fragment onto the path
  # string. Sorted for stable output; values interpolate like path params
  # (a produced ref renders as `state.refs["name"]`).
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

    opts =
      if resolved_body do
        opts ++ ["json: #{generate_body_map(resolved_body)}"]
      else
        opts
      end

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

  # A variable ref renders as a `state.refs[...]` lookup. Collections carrying a
  # ref are rendered element-by-element so nested placeholders resolve; those
  # without a ref fall through to `inspect/1`, preserving prior output exactly.
  defp format_body_value(%StepPlan.Var{name: name}), do: "state.refs[#{inspect(name)}]"

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
  # State Tracking (DR-021 placeholder extraction)
  # ============================================================================

  defp generate_state_update(%StepPlan.Step{} = step) do
    puts =
      Enum.map_join(step.producer_bindings, "\n", fn {path, var} ->
        key = inspect(var)

        "state = put_in(state, [:refs, #{key}], get_in(resp.body, #{ex_access(path)}))"
      end)

    if puts == "" do
      """

      IO.inspect(state, label: "State")
      """
    else
      """

      # Bind external values produced by this command (DR-021)
      #{puts}
      IO.inspect(state, label: "State")
      """
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

  # ============================================================================
  # Exploration Section
  # ============================================================================

  defp generate_exploration_section(_base_url) do
    """
    ## Exploration

    Use this section to experiment with variations and understand the bug better.

    ```elixir
    # Try different values or additional commands here
    # The `state` variable contains refs bound from previous steps
    # The `base_url` is available for making HTTP calls

    IO.puts("Available refs: \#{inspect(Map.keys(state.refs))}")

    # Example: Try a different operation
    # Req.post!(base_url <> "/api/...", json: %{...})

    # Example: Inspect current state
    IO.inspect(state, label: "Current state")
    ```

    ### What to Try

    - Modify amounts/values in the command sequence above and re-run
    - Add additional commands to see how state evolves
    - Comment out commands to find the minimal reproduction
    - Try boundary values (0, -1, max int, etc.)

    ```elixir
    # Notes and observations
    # -----------------------
    #
    # Add your findings here as you investigate
    #
    ```
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp generate_title(metadata) do
    case metadata.check_name do
      nil -> "Failure Investigation: #{metadata.failure_type}"
      check -> "Failure Investigation: #{check}"
    end
  end
end
