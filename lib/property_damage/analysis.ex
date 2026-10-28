defmodule PropertyDamage.Analysis do
  @moduledoc """
  Advanced failure analysis tools for understanding and debugging test failures.

  This module provides tools that go beyond basic shrinking to help users
  understand *why* a failure occurs and *what* specifically triggers it.

  ## Features

  - **Causal Explanation**: Understand why each command in the shrunk sequence is needed
  - **Trigger Isolation**: Find the minimal change that eliminates the failure
  - **Test Generation**: Generate reproducible test code from failures

  ## Roles

  `explain/1` infers a command's role from the placeholders alone. The failing
  command is the `:trigger`. A command that produces a value the failing
  command consumes, directly or through other placeholders, is a
  `:dependency`. Any other command has the role `:unknown`: no placeholder
  links it to the failure. When the failure is localized, the shrinker kept it
  because removing it lost the failure, so it may set up state the failing
  command reads (a deposit that only supplies a balance). `explain/1` does not
  infer that dependency, so such a command stays out of the dependency chain.

  ## Usage

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Understand why each command is needed
      PropertyDamage.Analysis.explain(failure)

      # Find what triggers the bug
      PropertyDamage.Analysis.isolate_trigger(failure)

      # Generate a test case
      PropertyDamage.Analysis.generate_test(failure, format: :exunit)
  """

  alias PropertyDamage.{
    Executor,
    Expansion,
    FailureReport,
    Options,
    Placeholder,
    PlaceholderRegistry,
    ReplayArtifact,
    RunTrace,
    Scheduler,
    Sequence
  }

  alias PropertyDamage.Sequence.Validator
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
    steps = FailureReport.steps(report)
    commands = Enum.map(steps, & &1.command)

    # The dependency graph is built over the flattened command list and indexed
    # by flattened (reading) order, so the failing node must be the flattened
    # index. failed_at_index is an executor index and diverges from it for
    # branch failures, so read it off the already-materialized failed step
    # (nil for a non-localized failure).
    failed_at = Enum.find_value(steps, fn step -> step.failed? && step.flattened_index end)

    # Build the authoritative producer map from the report's plan registry.
    # The plan carried here is the shrunk sequence, whose embedded placeholder
    # positions are stale original offsets (the shrinker remaps the registry's
    # producer_link, not the embedded structs). Deriving producers from those
    # positions would key edges to the wrong node or a node past the end of the
    # shrunk list, so build the map from the current registry positions instead.
    producers = plan_producers(FailureReport.shrunk_sequence(report))

    # Build dependency graph
    graph = Graph.build(commands, producers)

    # Find which commands are ancestors of the failing command. A non-localized
    # failure (failed_at nil) has no failing node to trace ancestors from.
    ancestors = if failed_at, do: Graph.ancestors(graph, failed_at), else: MapSet.new()

    # Analyze each command
    localized? = failed_at != nil

    command_explanations =
      Enum.map(steps, fn step ->
        analyze_command(step, ancestors, report, localized?)
      end)

    %{
      summary: build_summary(command_explanations, report),
      commands: command_explanations,
      failure: %{
        type: FailureReport.failure_type(report),
        check: FailureReport.check_name(report),
        message: FailureReport.failure_message(report),
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

  defp analyze_command(%RunTrace.Step{} = step, ancestors, report, localized?) do
    cmd = step.command
    idx = step.flattened_index
    cmd_name = cmd.__struct__ |> Module.split() |> List.last()

    {role, reason} =
      cond do
        step.failed? ->
          {:trigger, "Triggers #{failure_label(report)} failure"}

        MapSet.member?(ancestors, idx) ->
          # Ancestor in the dependency graph: produces state or values the
          # failing command depends on.
          {:dependency, "Provides state or values required by the failing command"}

        not localized? ->
          # The failure was not localized to a specific command (teardown /
          # whole-run / linearization check), so no per-command role applies.
          {:unknown, "Failure not localized to a specific command"}

        true ->
          # No placeholder links it to the failing command, yet the shrinker
          # kept it: removing it lost the failure, so it may set up state the
          # failing command reads.
          {:unknown,
           "Kept by shrinking: removing it lost the failure; it may set up state the failing command reads"}
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

  defp extract_refs(cmd) do
    cmd
    |> Map.from_struct()
    |> Enum.filter(fn {_k, v} -> match?(%Placeholder{}, v) end)
    |> Enum.map(fn {k, %Placeholder{} = p} -> {k, placeholder_label(p)} end)
    |> Map.new()
  end

  defp placeholder_label(%Placeholder{path: path, position: position}) do
    path_str = Enum.map_join(path, ".", &to_string/1)
    "placeholder:#{path_str}@#{inspect(position)}"
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
    #{if deps != [], do: "Dependencies: #{length(deps)} command(s) required to set up state", else: ""}
    Failure type: #{FailureReport.failure_type_summary(report)}
    """
    |> String.trim()
  end

  # A non-localized failure (teardown / whole-run / linearization check) has no
  # failing node to trace a chain from, so there is nothing to build.
  defp build_dependency_chain(nil, _graph, _commands), do: []

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

  # Build the graph's producer map from the plan's registry (DR-021). The
  # registry's `producer_link` maps each CURRENT producer position to the
  # placeholder ids it produces (already remapped by the shrinker), and
  # `Sequence.indexed/1` is the single owner of the position -> flattened-index
  # mapping (branching-aware). Positions absent from the plan (dropped
  # producers) contribute nothing. Returns nil when there is no registry (an
  # unshrunk report, or a model without placeholders), so `Graph.build/2` falls
  # back to the embedded-position fallback, which is correct in that case.
  defp plan_producers(
         %Sequence{registry: %PlaceholderRegistry{producer_link: producer_link}} = plan
       ) do
    position_to_index =
      plan
      |> Sequence.indexed()
      |> Map.new(fn {position, flattened_index, _command} -> {position, flattened_index} end)

    Enum.reduce(producer_link, %{}, fn {position, ids}, acc ->
      case Map.fetch(position_to_index, position) do
        {:ok, index} ->
          Enum.reduce(ids, acc, fn id, inner -> Map.put(inner, {:placeholder, id}, index) end)

        :error ->
          acc
      end
    end)
  end

  defp plan_producers(_plan), do: nil

  # ============================================================================
  # Trigger Isolation
  # ============================================================================

  @doc """
  Find the minimal change that eliminates the failure.

  This performs differential analysis to identify exactly what triggers the bug.
  It tries variations of the failing command to find the smallest change that
  makes the failure disappear.

  For a model with `c:PropertyDamage.Model.expansions/0` whose reference ran
  roots of the report as an expansion's leaves, the analysis works on the
  reference's concrete sequence, leaves included: it reads what the
  reference ran from the report's `replay` term (or its trace), varies the
  one concrete command where the failure was found, and re-runs the
  reference alone with the other commands as they ran. A target other than
  the reference that ran leaves is refused with `ArgumentError`.

  Every variation runs one target alone, in leaf mode and root mode alike, so
  no variation can show a divergence or a failure to converge, which take two
  targets: a `:diverged` or `:did_not_converge` report returns
  `{:error, :not_applicable}`.

  ## Options

  - `:targets` - Single-entry target list overriding the system to re-execute
    against (default: the report's reference target: its adapter, name and
    `config:`); see
    `PropertyDamage.Target`

  ## Returns

  `{:ok, map}`, or `{:error, reason}`: `:not_applicable` for a divergence or
  a failure to converge, `:failure_not_localized` when no command is to
  blame, `:missing_model_or_target` when the report records no model or no
  target. The map contains:
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
    sequence = FailureReport.shrunk_sequence(report)
    commands = Sequence.to_list(sequence)
    # `commands` is the flattened list the modified sequence is re-run against,
    # so the trigger is addressed by its step's flattened index (not the
    # executor failed_at_index, which diverges for branch failures).
    step = FailureReport.failure_step(report)
    model = report.model
    reference = FailureReport.reference_target(report)

    cond do
      is_nil(step) ->
        # Non-localized failure (teardown / whole-run / linearization): there is
        # no single trigger command to vary.
        {:error, :failure_not_localized}

      is_nil(model) or is_nil(reference) ->
        {:error, :missing_model_or_target}

      true ->
        # The target comes from opts, else the report's reference target
        target =
          Options.override_target!(opts, reference, "PropertyDamage.Analysis.isolate_trigger/2")

        case {report.kind, reference_leaves(report, model, target)} do
          # A divergence takes two targets; every variation runs one.
          {kind, _leaves} when kind in [:diverged, :did_not_converge] -> {:error, :not_applicable}
          {_kind, nil} -> isolate_in_roots(report, model, target, {sequence, commands, step})
          {_kind, leaves} -> isolate_in_leaves(report, model, target, leaves)
        end
    end
  end

  # The trigger among the roots, each run as itself on the linear engine.
  defp isolate_in_roots(report, model, target, {sequence, commands, step}) do
    failed_at = step.flattened_index
    trigger_cmd = step.command

    # Try variations of the trigger command
    # Every variation runs with the report's setup and teardown commands
    # and the sequence's registry, so the roots resolve the externals the
    # setup commands produce.
    run = %{
      model: model,
      target: target,
      registry: sequence.registry,
      setup_commands: report.setup_commands,
      teardown_commands: report.teardown_commands
    }

    changes = find_eliminating_changes(trigger_cmd, commands, failed_at, run)
    trigger_result(report, trigger_cmd, commands, failed_at, changes)
  end

  # The trigger among the reference's concrete commands: the command where
  # the failure was found, a leaf when the reference ran the failing root as
  # leaves. Each variation runs the reference alone with every other command
  # as it ran.
  defp isolate_in_leaves(report, model, target, {sequence, variant}) do
    executed = (report.trace && report.trace.executed) || %{}

    steps =
      RunTrace.build_steps(sequence, [], %{}, report.failed_at_index,
        executed: executed,
        choices: variant.choices
      )

    case Enum.find(steps, & &1.failed?) do
      nil ->
        {:error, :failure_not_localized}

      step ->
        commands = Enum.flat_map(variant.choices, & &1.commands)

        run = %{
          model: model,
          target: target,
          leaves: {sequence, variant},
          seed: report.seed,
          setup_commands: report.setup_commands,
          teardown_commands: report.teardown_commands
        }

        changes = find_eliminating_changes(step.command, commands, step.flattened_index, run)
        trigger_result(report, step.command, commands, step.flattened_index, changes)
    end
  end

  defp trigger_result(report, trigger_cmd, commands, failed_at, changes) do
    {:ok,
     %{
       trigger_command: trigger_cmd,
       trigger_index: failed_at,
       changes: changes,
       likely_cause: infer_cause(changes, trigger_cmd, commands, report)
     }}
  end

  # What `target` ran when the reference ran roots as an expansion's leaves:
  # `{sequence, variant}` from the report's replay term (or its trace); nil
  # when the target ran every root as itself, which the linear engine
  # re-runs. A target other than the reference that ran leaves is refused:
  # only the reference's concrete sequence is varied.
  defp reference_leaves(report, model, target) do
    path = "PropertyDamage.Analysis.isolate_trigger/2"
    {sequence, variants} = ReplayArtifact.reexecution(report, [target.name], path)
    variant = variants && Map.fetch!(variants, target.name)

    cond do
      is_nil(variant) or not Enum.any?(variant.choices, & &1.leaves?) ->
        nil

      target.name == FailureReport.reference_target(report).name ->
        {sequence, variant}

      true ->
        raise ArgumentError,
              "#{path} varies one command and re-runs the roots as themselves, but target " <>
                "#{inspect(target.name)} ran roots of this report as an expansion's leaves " <>
                "(#{inspect(model)} defines expansions/0); only the reference's expanded " <>
                "sequence can be varied"
    end
  end

  defp find_eliminating_changes(trigger_cmd, commands, failed_at, run) do
    trigger_cmd
    |> Map.from_struct()
    |> Enum.reject(fn {k, _v} -> k in [:__struct__, :idempotency_key] end)
    |> Enum.flat_map(fn {field, original_value} ->
      try_field_variations(field, original_value, trigger_cmd, commands, failed_at, run)
    end)
  end

  defp try_field_variations(field, original, trigger_cmd, commands, failed_at, run) do
    # Skip placeholder fields - can't change those without breaking dependencies
    if match?(%Placeholder{}, original) do
      []
    else
      variations = generate_variations(field, original, commands, failed_at)

      Enum.flat_map(variations, fn variation ->
        modified_cmd = Map.put(trigger_cmd, field, variation)
        modified_commands = List.replace_at(commands, failed_at, modified_cmd)

        if eliminates?(modified_commands, run) do
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
      end)
    end
  end

  # Whether the commands, one of them varied, run without the failure: the
  # reference's concrete commands at their positions, or the roots on the
  # linear engine when they are valid from the state the setup commands
  # leave.
  defp eliminates?(commands, %{leaves: {sequence, variant}} = run) do
    {choices, []} =
      Enum.map_reduce(variant.choices, regenerate_keys(commands), fn choice, rest ->
        {ran, rest} = Enum.split(rest, length(choice.commands))
        {%{choice | commands: ran}, rest}
      end)

    {:ok, outcome} =
      Scheduler.run(
        model: run.model,
        targets: [%{run.target | index: 0}],
        commands: Sequence.to_list(sequence),
        variants: [%{roots: Expansion.steps(choices), registry: variant.registry}],
        setup_commands: run.setup_commands,
        teardown_commands: run.teardown_commands,
        placeholder_registry: sequence.registry,
        seed: run.seed,
        run_number: 0,
        concurrency: :serial
      )

    is_nil(outcome.failure)
  end

  defp eliminates?(commands, run) do
    if Validator.valid_sequence?(commands, run.model, run.setup_commands) do
      sequence = Sequence.with_registry(Sequence.linear(regenerate_keys(commands)), run.registry)

      case Executor.run(sequence, run.model, run.target.adapter,
             config: run.target.config,
             setup_commands: run.setup_commands,
             teardown_commands: run.teardown_commands
           ) do
        {:ok, result} -> result.success
        {:error, _} -> false
      end
    else
      false
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

  ## Example

      PropertyDamage.Analysis.generate_test(failure, format: :exunit)
      # Generates ExUnit test code
  """
  @spec generate_test(FailureReport.t(), keyword()) :: String.t()
  def generate_test(%FailureReport{} = report, opts \\ []) do
    opts = PropertyDamage.Options.validate_generate_test!(opts)
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
    commands = Sequence.to_list(FailureReport.shrunk_sequence(report))

    command_code = generate_command_code(commands)
    check_name = failure_label(report)

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
          targets: #{FailureReport.targets_source(report)},
          seed: #{report.seed},
          max_runs: 1
        )

        # This should fail with the same error
        assert {:error, failure} = result
        assert PropertyDamage.FailureReport.check_name(failure) == #{inspect(FailureReport.check_name(report))}
      end

      @tag :reproduction
      @tag :manual
      test "manual reproduction of #{check_name} bug" do
        # The minimal sequence that triggers the failure:
    #{command_code}

        # The failure occurs at command index #{FailureReport.failure_index(report)}
        # Failure message: #{String.slice(FailureReport.failure_message(report) || "", 0, 100)}
      end
    end
    """
  end

  defp generate_script(report, _opts) do
    commands = Sequence.to_list(FailureReport.shrunk_sequence(report))
    command_code = generate_command_code(commands)

    """
    # Reproduction script for #{failure_label(report)} failure
    # Original seed: #{report.seed}
    # Run with: mix run reproduction.exs

    # Option 1: Re-run with same seed
    result = PropertyDamage.run(
      model: #{inspect(report.model)},
      targets: #{FailureReport.targets_source(report)},
      seed: #{report.seed},
      max_runs: 1
    )

    IO.inspect(result, label: "Result")

    # Option 2: The minimal failing sequence
    # #{length(commands)} commands, failure at index #{FailureReport.failure_index(report)}
    #
    #{command_code}
    """
  end

  defp generate_markdown(report, _opts) do
    commands = Sequence.to_list(FailureReport.shrunk_sequence(report))
    explanation = explain(report)

    """
    # Bug Report: #{failure_label(report)}

    ## Summary

    #{explanation.summary}

    ## Reproduction

    ```elixir
    PropertyDamage.run(
      model: #{inspect(report.model)},
      targets: #{FailureReport.targets_source(report)},
      seed: #{report.seed},
      max_runs: 1
    )
    ```

    ## Minimal Failing Sequence

    #{format_commands_markdown(commands, FailureReport.failure_index(report))}

    ## Failure Details

    - **Type**: #{FailureReport.failure_type(report)}
    - **Check**: #{if FailureReport.check_name(report), do: failure_label(report), else: "N/A"}
    - **Message**: #{FailureReport.failure_message(report) || "N/A"}
    - **Command Index**: #{FailureReport.failure_index(report)}

    ## Analysis

    #{format_explanation(explanation)}
    """
  end

  defp generate_command_code(commands) do
    commands
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {cmd, idx} ->
      cmd_name = cmd.__struct__ |> Module.split() |> List.last()
      fields = cmd |> Map.from_struct() |> Map.drop([:__struct__]) |> inspect()
      "    # [#{idx}] #{cmd_name}\n    # #{fields}"
    end)
  end

  defp format_commands_markdown(commands, failed_at) do
    commands
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, idx} ->
      cmd_name = cmd.__struct__ |> Module.split() |> List.last()
      marker = if idx == failed_at, do: " ← **FAILURE**", else: ""
      fields = format_command_fields(cmd)
      "#{idx}. `#{cmd_name}`#{marker}\n   - #{fields}"
    end)
  end

  defp format_command_fields(cmd) do
    cmd
    |> Map.from_struct()
    |> Map.drop([:__struct__, :idempotency_key])
    |> Enum.map_join(", ", fn {k, v} ->
      case v do
        %Placeholder{} -> "#{k}: <placeholder>"
        _ -> "#{k}: #{inspect(v)}"
      end
    end)
  end

  # The failing check or observation as text, else the failure's kind.
  defp failure_label(report) do
    case FailureReport.check_name(report) do
      nil -> to_string(FailureReport.failure_type(report))
      name -> FailureReport.format_name(name)
    end
  end
end
