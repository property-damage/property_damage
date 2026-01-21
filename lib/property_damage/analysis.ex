defmodule PropertyDamage.Analysis do
  @moduledoc """
  Advanced failure analysis tools for understanding and debugging test failures.

  This module provides tools that go beyond basic shrinking to help users
  understand *why* a failure occurs and *what* specifically triggers it.

  ## Features

  - **Causal Explanation**: Understand why each command in the shrunk sequence is needed
  - **Trigger Isolation**: Find the minimal change that eliminates the failure
  - **Test Generation**: Generate reproducible test code from failures

  ## Usage

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)

      # Understand why each command is needed
      PropertyDamage.Analysis.explain(failure)

      # Find what triggers the bug
      PropertyDamage.Analysis.isolate_trigger(failure)

      # Generate a test case
      PropertyDamage.Analysis.generate_test(failure, format: :exunit)
  """

  alias PropertyDamage.{FailureReport, Sequence, Executor, Validator, Ref, Placeholder}
  alias PropertyDamage.Shrinker.Graph

  # ============================================================================
  # Causal Explanation
  # ============================================================================

  @doc """
  Explain why each command in the shrunk sequence is needed for the failure.

  Returns a structured explanation showing:
  - The dependency graph between commands
  - Which command triggers the failure
  - Why each other command must be present

  ## Example

      PropertyDamage.Analysis.explain(failure)
      # Returns:
      # %{
      #   commands: [
      #     %{index: 0, command: "CreateAccount", role: :dependency,
      #       reason: "Creates account used by command 2"},
      #     %{index: 1, command: "CreateAuthorization", role: :dependency,
      #       reason: "Creates pending hold affecting available balance"},
      #     %{index: 2, command: "CreditAccount", role: :trigger,
      #       reason: "Causes currency_consistency check to fail"}
      #   ],
      #   failure: %{type: :check_failed, check: :currency_consistency, ...}
      # }
  """
  @spec explain(FailureReport.t()) :: map()
  def explain(%FailureReport{} = report) do
    commands = Sequence.to_list(report.shrunk_sequence)
    failed_at = report.failed_at_index

    # Build dependency graph
    graph = Graph.build(commands)

    # Find which commands are ancestors of the failing command
    ancestors = Graph.ancestors(graph, failed_at)

    # Analyze each command
    command_explanations =
      commands
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        analyze_command(cmd, idx, failed_at, ancestors, graph, commands, report)
      end)

    %{
      summary: build_summary(command_explanations, report),
      commands: command_explanations,
      failure: %{
        type: report.failure_type,
        check: report.check_name,
        message: report.failure_message,
        command_index: failed_at
      },
      dependency_chain: build_dependency_chain(failed_at, graph, commands)
    }
  end

  @doc """
  Format an explanation as a human-readable string.
  """
  @spec format_explanation(map()) :: String.t()
  def format_explanation(explanation) do
    lines = [
      "=" |> String.duplicate(60),
      "FAILURE ANALYSIS",
      "=" |> String.duplicate(60),
      "",
      explanation.summary,
      "",
      "-" |> String.duplicate(60),
      "COMMAND BREAKDOWN",
      "-" |> String.duplicate(60),
      ""
    ]

    command_lines =
      Enum.flat_map(explanation.commands, fn cmd ->
        role_marker =
          case cmd.role do
            :trigger -> "← FAILURE TRIGGER"
            :dependency -> "← DEPENDENCY"
            :unknown -> ""
          end

        [
          "[#{cmd.index}] #{cmd.command_name} #{role_marker}",
          "    #{cmd.reason}",
          format_refs(cmd.refs),
          ""
        ]
        |> Enum.reject(&is_nil/1)
      end)

    chain_lines =
      if explanation.dependency_chain != [] do
        [
          "-" |> String.duplicate(60),
          "DEPENDENCY CHAIN",
          "-" |> String.duplicate(60),
          "",
          Enum.join(explanation.dependency_chain, " → "),
          ""
        ]
      else
        []
      end

    Enum.join(lines ++ command_lines ++ chain_lines, "\n")
  end

  defp analyze_command(cmd, idx, failed_at, ancestors, _graph, commands, report) do
    cmd_name = cmd.__struct__ |> Module.split() |> List.last()

    {role, reason} =
      cond do
        idx == failed_at ->
          {:trigger, "Triggers #{report.check_name || report.failure_type} failure"}

        MapSet.member?(ancestors, idx) ->
          # This command is an ancestor - find what ref it provides
          ref_info = find_provided_ref(cmd, idx, commands, failed_at)
          {:dependency, ref_info}

        true ->
          # Not an ancestor and not the trigger - shouldn't be in shrunk sequence
          {:unknown, "Unknown role - may indicate shrinking issue"}
      end

    refs = extract_refs(cmd)

    %{
      index: idx,
      command_name: cmd_name,
      command: cmd,
      role: role,
      reason: reason,
      refs: refs
    }
  end

  defp find_provided_ref(cmd, idx, commands, failed_at) do
    cmd_module = cmd.__struct__

    if function_exported?(cmd_module, :creates_ref, 0) do
      case cmd_module.creates_ref() do
        nil ->
          "Required for state setup"

        ref_field ->
          ref = Map.get(cmd, ref_field)

          # Find who uses this ref
          users =
            commands
            |> Enum.with_index()
            |> Enum.filter(fn {other_cmd, other_idx} ->
              other_idx > idx and other_idx <= failed_at and uses_ref?(other_cmd, ref)
            end)
            |> Enum.map(fn {_, other_idx} -> other_idx end)

          if users == [] do
            "Creates ref used in failure context"
          else
            user_list = Enum.join(users, ", ")
            "Creates ref used by command(s) [#{user_list}]"
          end
      end
    else
      "Required for state setup"
    end
  end

  defp uses_ref?(cmd, %Ref{ref: ref_id}) do
    cmd
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(fn
      %Ref{ref: id} -> id == ref_id
      _ -> false
    end)
  end

  defp uses_ref?(cmd, %Placeholder{id: placeholder_id}) do
    cmd
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(fn
      %Placeholder{id: id} -> id == placeholder_id
      _ -> false
    end)
  end

  defp uses_ref?(_, _), do: false

  defp extract_refs(cmd) do
    cmd
    |> Map.from_struct()
    |> Enum.filter(fn {_k, v} -> match?(%Ref{}, v) or match?(%Placeholder{}, v) end)
    |> Enum.map(fn
      {k, %Ref{} = ref} -> {k, ref_label(ref)}
      {k, %Placeholder{} = p} -> {k, placeholder_label(p)}
    end)
    |> Map.new()
  end

  defp ref_label(%Ref{label: label}) when is_binary(label), do: label
  defp ref_label(%Ref{ref: ref}), do: "##{:erlang.phash2(ref)}"

  defp placeholder_label(%Placeholder{path: path, command_index: cmd_idx}) do
    path_str = Enum.map_join(path, ".", &to_string/1)
    "placeholder:#{path_str}@cmd#{cmd_idx}"
  end

  defp format_refs(refs) when map_size(refs) == 0, do: nil

  defp format_refs(refs) do
    ref_strs = Enum.map(refs, fn {k, v} -> "#{k}=#{v}" end)
    "    Refs: #{Enum.join(ref_strs, ", ")}"
  end

  defp build_summary(command_explanations, report) do
    trigger = Enum.find(command_explanations, &(&1.role == :trigger))
    deps = Enum.filter(command_explanations, &(&1.role == :dependency))

    """
    Shrunk to #{length(command_explanations)} commands.
    #{if trigger, do: "Failure triggered by: #{trigger.command_name} at index #{trigger.index}", else: ""}
    #{if length(deps) > 0, do: "Dependencies: #{length(deps)} command(s) required to set up state", else: ""}
    Failure type: #{FailureReport.failure_type_summary(report)}
    """
    |> String.trim()
  end

  defp build_dependency_chain(failed_at, graph, commands) do
    # Build chain from root to failure
    chain = build_chain_recursive(failed_at, graph, [])

    Enum.map(chain, fn idx ->
      cmd = Enum.at(commands, idx)
      cmd_name = cmd.__struct__ |> Module.split() |> List.last()
      "[#{idx}] #{cmd_name}"
    end)
  end

  defp build_chain_recursive(node, graph, visited) do
    if node in visited do
      []
    else
      # Find direct parents
      parents =
        graph.edges
        |> Enum.filter(fn {_from, to_set} -> MapSet.member?(to_set, node) end)
        |> Enum.map(fn {from, _} -> from end)

      case parents do
        [] ->
          [node]

        [parent | _] ->
          build_chain_recursive(parent, graph, [node | visited]) ++ [node]
      end
    end
  end

  # ============================================================================
  # Trigger Isolation
  # ============================================================================

  @doc """
  Find the minimal change that eliminates the failure.

  This performs differential analysis to identify exactly what triggers the bug.
  It tries variations of the failing command to find the smallest change that
  makes the failure disappear.

  ## Returns

  A map containing:
  - `:trigger_command` - The command that triggers the failure
  - `:changes` - List of changes that eliminate the failure
  - `:likely_cause` - Inferred cause based on the changes

  ## Example

      PropertyDamage.Analysis.isolate_trigger(failure)
      # %{
      #   trigger_command: %CreditAccount{...},
      #   changes: [
      #     %{field: :currency, original: "EUR", fixed: "USD",
      #       description: "Changing currency from EUR to USD eliminates failure"}
      #   ],
      #   likely_cause: "Currency mismatch: account currency (USD) differs from operation currency (EUR)"
      # }
  """
  @spec isolate_trigger(FailureReport.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def isolate_trigger(%FailureReport{} = report, opts \\ []) do
    commands = Sequence.to_list(report.shrunk_sequence)
    failed_at = report.failed_at_index
    trigger_cmd = Enum.at(commands, failed_at)
    model = report.model
    adapter = report.adapter

    if is_nil(model) or is_nil(adapter) do
      {:error, :missing_model_or_adapter}
    else
      # Get adapter config from opts or use empty
      adapter_config = Keyword.get(opts, :adapter_config, %{})

      # Try variations of the trigger command
      changes =
        find_eliminating_changes(trigger_cmd, commands, failed_at, model, adapter, adapter_config)

      likely_cause = infer_cause(changes, trigger_cmd, commands, report)

      {:ok,
       %{
         trigger_command: trigger_cmd,
         trigger_index: failed_at,
         changes: changes,
         likely_cause: likely_cause
       }}
    end
  end

  defp find_eliminating_changes(trigger_cmd, commands, failed_at, model, adapter, adapter_config) do
    trigger_cmd
    |> Map.from_struct()
    |> Enum.reject(fn {k, _v} -> k in [:__struct__, :idempotency_key] end)
    |> Enum.flat_map(fn {field, original_value} ->
      try_field_variations(
        field,
        original_value,
        trigger_cmd,
        commands,
        failed_at,
        model,
        adapter,
        adapter_config
      )
    end)
  end

  defp try_field_variations(
         field,
         original,
         trigger_cmd,
         commands,
         failed_at,
         model,
         adapter,
         adapter_config
       ) do
    # Skip ref and placeholder fields - can't change those without breaking dependencies
    if match?(%Ref{}, original) or match?(%Placeholder{}, original) do
      []
    else
      variations = generate_variations(field, original, commands, failed_at)

      Enum.flat_map(variations, fn variation ->
        modified_cmd = Map.put(trigger_cmd, field, variation)
        modified_commands = List.replace_at(commands, failed_at, modified_cmd)

        # Check if modification is valid and eliminates failure
        if Validator.valid_sequence?(modified_commands, model) do
          # Regenerate idempotency keys
          modified_commands = regenerate_keys(modified_commands)

          # Call setup_each before testing
          if function_exported?(model, :setup_each, 1) do
            model.setup_each(%{adapter_config: adapter_config})
          end

          case Executor.run(modified_commands, model, adapter, adapter_config: adapter_config) do
            {:ok, result} ->
              if result.success do
                [
                  %{
                    field: field,
                    original: original,
                    fixed: variation,
                    description:
                      "Changing #{field} from #{inspect(original)} to #{inspect(variation)} eliminates failure"
                  }
                ]
              else
                []
              end

            {:error, _} ->
              []
          end
        else
          []
        end
      end)
    end
  end

  defp generate_variations(field, original, commands, failed_at) when is_binary(original) do
    # For strings (like currency), try values from other commands
    other_values =
      commands
      |> Enum.take(failed_at)
      |> Enum.flat_map(fn cmd ->
        cmd
        |> Map.from_struct()
        |> Enum.filter(fn {k, v} -> k == field and is_binary(v) and v != original end)
        |> Enum.map(fn {_, v} -> v end)
      end)
      |> Enum.uniq()

    # Also try empty and common variations
    base_variations = if byte_size(original) > 0, do: [""], else: []

    Enum.take(other_values ++ base_variations, 5)
  end

  defp generate_variations(_field, original, _commands, _failed_at) when is_integer(original) do
    # For integers, try 0 and some nearby values
    variations = [0, 1, original - 1, original + 1, div(original, 2)]
    Enum.filter(variations, &(&1 != original and &1 >= 0))
  end

  defp generate_variations(_field, _original, _commands, _failed_at) do
    # For other types, no automatic variations
    []
  end

  defp infer_cause(changes, trigger_cmd, commands, _report) do
    cond do
      # Currency mismatch pattern
      currency_change = Enum.find(changes, &(&1.field == :currency)) ->
        # Find what the account's currency is
        account_currency = find_account_currency(trigger_cmd, commands)

        if account_currency do
          "Currency mismatch: operation uses #{inspect(currency_change.original)} but account uses #{inspect(account_currency)}"
        else
          "Currency mismatch detected - changing currency eliminates failure"
        end

      # Amount-related pattern
      amount_change = Enum.find(changes, &(&1.field == :amount)) ->
        "Amount-related issue: original amount #{amount_change.original} causes failure"

      # No changes found
      changes == [] ->
        "Unable to isolate trigger through field variation. The failure may depend on command ordering or complex state."

      # Generic case
      true ->
        change = hd(changes)

        "Changing #{change.field} from #{inspect(change.original)} to #{inspect(change.fixed)} eliminates failure"
    end
  end

  defp find_account_currency(trigger_cmd, commands) do
    account_ref = Map.get(trigger_cmd, :account_ref)

    if account_ref do
      # Find the CreateAccount command that creates this ref
      Enum.find_value(commands, fn cmd ->
        cmd_module = cmd.__struct__
        name = cmd_module |> Module.split() |> List.last()

        if name == "CreateAccount" do
          cmd_ref = Map.get(cmd, :account_ref)

          if cmd_ref && cmd_ref.ref == account_ref.ref do
            Map.get(cmd, :currency)
          end
        end
      end)
    end
  end

  defp regenerate_keys(commands) do
    Enum.map(commands, fn cmd ->
      if Map.has_key?(cmd, :idempotency_key) do
        %{cmd | idempotency_key: :crypto.strong_rand_bytes(16) |> Base.encode16()}
      else
        cmd
      end
    end)
  end

  # ============================================================================
  # Test Generation
  # ============================================================================

  @doc """
  Generate a reproducible test case from a failure.

  Creates runnable code that reproduces the failure, suitable for adding
  to a test suite or sharing with colleagues.

  ## Options

  - `:format` - Output format (`:exunit`, `:script`, `:markdown`). Default: `:exunit`
  - `:module_name` - Module name for ExUnit tests. Default: "ReproductionTest"
  - `:include_setup` - Include model/adapter setup code. Default: true

  ## Example

      PropertyDamage.Analysis.generate_test(failure, format: :exunit)
      # Generates ExUnit test code
  """
  @spec generate_test(FailureReport.t(), keyword()) :: String.t()
  def generate_test(%FailureReport{} = report, opts \\ []) do
    format = Keyword.get(opts, :format, :exunit)

    case format do
      :exunit -> generate_exunit_test(report, opts)
      :script -> generate_script(report, opts)
      :markdown -> generate_markdown(report, opts)
      _ -> generate_exunit_test(report, opts)
    end
  end

  defp generate_exunit_test(report, opts) do
    module_name = Keyword.get(opts, :module_name, "ReproductionTest")
    commands = Sequence.to_list(report.shrunk_sequence)

    command_code = generate_command_code(commands)
    check_name = report.check_name || report.failure_type

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Reproduction test for #{check_name} failure.

      Generated from PropertyDamage failure report.
      Original seed: #{report.seed}
      Shrunk from #{Sequence.command_count(report.original_sequence)} to #{length(commands)} commands.
      \"\"\"

      use ExUnit.Case

      @tag :reproduction
      test "reproduces #{check_name} bug (seed: #{report.seed})" do
        # Run the exact sequence that triggered the failure
        result = PropertyDamage.run(
          model: #{inspect(report.model)},
          adapter: #{inspect(report.adapter)},
          seed: #{report.seed},
          max_runs: 1
        )

        # This should fail with the same error
        assert {:error, failure} = result
        assert failure.check_name == #{inspect(report.check_name)}
      end

      @tag :reproduction
      @tag :manual
      test "manual reproduction of #{check_name} bug" do
        # The minimal sequence that triggers the failure:
    #{command_code}

        # The failure occurs at command index #{report.failed_at_index}
        # Failure message: #{String.slice(report.failure_message || "", 0, 100)}
      end
    end
    """
  end

  defp generate_script(report, _opts) do
    commands = Sequence.to_list(report.shrunk_sequence)
    command_code = generate_command_code(commands)

    """
    # Reproduction script for #{report.check_name || report.failure_type} failure
    # Original seed: #{report.seed}
    # Run with: mix run reproduction.exs

    # Option 1: Re-run with same seed
    result = PropertyDamage.run(
      model: #{inspect(report.model)},
      adapter: #{inspect(report.adapter)},
      seed: #{report.seed},
      max_runs: 1
    )

    IO.inspect(result, label: "Result")

    # Option 2: The minimal failing sequence
    # #{length(commands)} commands, failure at index #{report.failed_at_index}
    #
    #{command_code}
    """
  end

  defp generate_markdown(report, _opts) do
    commands = Sequence.to_list(report.shrunk_sequence)
    explanation = explain(report)

    """
    # Bug Report: #{report.check_name || report.failure_type}

    ## Summary

    #{explanation.summary}

    ## Reproduction

    ```elixir
    PropertyDamage.run(
      model: #{inspect(report.model)},
      adapter: #{inspect(report.adapter)},
      seed: #{report.seed},
      max_runs: 1
    )
    ```

    ## Minimal Failing Sequence

    #{format_commands_markdown(commands, report.failed_at_index)}

    ## Failure Details

    - **Type**: #{report.failure_type}
    - **Check**: #{report.check_name || "N/A"}
    - **Message**: #{report.failure_message || "N/A"}
    - **Command Index**: #{report.failed_at_index}

    ## Analysis

    #{format_explanation(explanation)}
    """
  end

  defp generate_command_code(commands) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      cmd_name = cmd.__struct__ |> Module.split() |> List.last()
      fields = cmd |> Map.from_struct() |> Map.drop([:__struct__]) |> inspect()
      "    # [#{idx}] #{cmd_name}\n    # #{fields}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_commands_markdown(commands, failed_at) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      cmd_name = cmd.__struct__ |> Module.split() |> List.last()
      marker = if idx == failed_at, do: " ← **FAILURE**", else: ""
      fields = format_command_fields(cmd)
      "#{idx}. `#{cmd_name}`#{marker}\n   - #{fields}"
    end)
    |> Enum.join("\n")
  end

  defp format_command_fields(cmd) do
    cmd
    |> Map.from_struct()
    |> Map.drop([:__struct__, :idempotency_key])
    |> Enum.map(fn {k, v} ->
      case v do
        %Ref{} -> "#{k}: <ref>"
        _ -> "#{k}: #{inspect(v)}"
      end
    end)
    |> Enum.join(", ")
  end
end
