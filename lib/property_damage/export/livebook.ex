defmodule PropertyDamage.Export.LiveBook do
  @moduledoc """
  Generates LiveBook notebooks for interactive failure exploration.

  The generated notebooks:
  - Use Req for HTTP calls
  - Track state alongside execution
  - Allow step-by-step execution
  - Include an exploration section for "what-if" scenarios

  ## Usage

      notebook = PropertyDamage.Export.LiveBook.generate(failure,
        base_url: "http://localhost:4000",
        adapter: MyHTTPAdapter
      )

      File.write!("failure_investigation.livemd", notebook)
  """

  alias PropertyDamage.Export.{Common, HTTPSpec}
  alias PropertyDamage.{FailureReport, Placeholder}

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
    commands = Common.extract_commands(report)
    title = Keyword.get(opts, :title, generate_title(metadata))

    var_map = Common.placeholder_var_map(commands)
    extractions = Common.producer_extractions(commands)

    sections = [
      generate_header(title, metadata),
      generate_setup_section(base_url, include_state),
      generate_command_sections(commands, report, adapter, include_state, var_map, extractions)
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

  defp generate_command_sections(commands, report, adapter, include_state, var_map, extractions) do
    header = "\n## Command Sequence\n"

    sections =
      commands
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        is_failure_point = idx == report.failed_at_index

        generate_command_section(
          cmd,
          idx,
          adapter,
          is_failure_point,
          include_state,
          var_map,
          extractions
        )
      end)

    [header | sections]
  end

  defp generate_command_section(
         command,
         index,
         adapter,
         is_failure_point,
         include_state,
         var_map,
         extractions
       ) do
    step_num = index + 1
    cmd_name = Common.command_name(command)
    http_spec = Common.get_http_spec(command, adapter, %{})

    failure_marker = if is_failure_point, do: " (FAILURE)", else: ""
    warning = if is_failure_point, do: "\n> ⚠️ **This command caused the failure**\n", else: ""

    code =
      generate_livebook_code(
        command,
        http_spec,
        index,
        include_state,
        is_failure_point,
        var_map,
        extractions
      )

    """
    ### Step #{step_num}: #{cmd_name}#{failure_marker}
    #{warning}
    ```elixir
    # Command: #{Common.command_to_comment(command)}
    #{code}
    ```
    """
  end

  defp generate_livebook_code(
         command,
         nil,
         _index,
         _include_state,
         _is_failure,
         _var_map,
         _extractions
       ) do
    cmd_name = Common.command_name(command)

    """
    # TODO: Add http_spec/2 to your adapter for #{cmd_name}
    IO.puts("No HTTP mapping available for #{cmd_name}")
    """
  end

  defp generate_livebook_code(
         command,
         %HTTPSpec{} = spec,
         index,
         include_state,
         is_failure,
         var_map,
         extractions
       ) do
    method = spec.method
    path = generate_path_code(spec, index, var_map)
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

    state_update =
      if include_state do
        generate_state_update(index, extractions)
      else
        ""
      end

    failure_check =
      if is_failure do
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

  defp generate_path_code(%HTTPSpec{path: path, path_params: params}, _index, var_map) do
    if map_size(params) == 0 do
      inspect(path)
    else
      resolved_path =
        Enum.reduce(params, path, fn {key, value}, acc ->
          replacement = generate_value_interpolation(value, var_map)
          String.replace(acc, ":#{key}", "\#{#{replacement}}")
        end)

      ~s("#{resolved_path}")
    end
  end

  defp generate_value_interpolation(%Placeholder{} = ph, var_map) do
    "state.refs[#{inspect(Map.fetch!(var_map, ph.id))}]"
  end

  defp generate_value_interpolation(value, _var_map) do
    inspect(value)
  end

  defp build_req_opts(spec, command, index, var_map) do
    opts = []

    opts =
      if HTTPSpec.has_body?(spec) do
        body = generate_body_map(spec.body, command, index, var_map)
        opts ++ ["json: #{body}"]
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
    "state.refs[#{inspect(Map.fetch!(var_map, ph.id))}]"
  end

  defp format_body_value(value, _cmd_index, _var_map) when is_atom(value), do: inspect(value)
  defp format_body_value(value, _cmd_index, _var_map), do: inspect(value)

  # ============================================================================
  # State Tracking (DR-021 placeholder extraction)
  # ============================================================================

  defp generate_state_update(index, extractions) do
    bindings = Map.get(extractions, index, [])

    puts =
      bindings
      |> Enum.map_join("\n", fn {ph, var} ->
        key = inspect(var)

        "state = put_in(state, [:refs, #{key}], get_in(resp.body, #{ex_access(ph.path)}))"
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
