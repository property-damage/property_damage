defmodule PropertyDamage.IEx do
  @moduledoc """
  Interactive helpers for exploring and debugging PropertyDamage models in IEx.

  These functions help you understand, test, and debug your models interactively.

  ## Quick Start

      iex> import PropertyDamage.IEx
      iex> explain(MyModel)
      iex> dry_run(MyModel, commands: 5)
      iex> debug_command(%CreateUser{name: "test"}, MyAdapter)

  ## Available Functions

  - `explain/1` - Show model structure (commands, projections, callbacks)
  - `dry_run/2` - Generate a command sequence without executing
  - `debug_command/3` - Execute a single command with detailed output
  - `inspect_state/2` - Show projection state after applying events
  - `check_preconditions/2` - See which commands are valid in a state
  """

  alias PropertyDamage.{Generator, Model, Sequence}

  # ============================================================================
  # explain/1 - Model Exploration
  # ============================================================================

  @doc """
  Display detailed information about a model.

  Shows commands (with weights), projections, optional callbacks,
  and helpful hints about the model's configuration.

  ## Examples

      iex> PropertyDamage.IEx.explain(ToyBankTest.Model)

      ═══════════════════════════════════════════════════════════════
                            ToyBankTest.Model
      ═══════════════════════════════════════════════════════════════

      COMMANDS (6 total)
      ─────────────────────────────────────────────────────────────────
        Weight │ Command                    │ Role     │ Creates Ref
      ─────────────────────────────────────────────────────────────────
           5   │ CreateAccount              │ action   │ :account
           3   │ Credit                     │ action   │ -
           3   │ Debit                      │ action   │ -
           2   │ CreateAuthorization        │ action   │ :authorization
           2   │ CreateCapture              │ action   │ -
           1   │ CloseAccount               │ action   │ -
      ...

  """
  @spec explain(module()) :: :ok
  def explain(model) do
    IO.puts("")
    print_header(model)
    print_commands(model)
    print_projections(model)
    print_optional_callbacks(model)
    print_hints(model)
    IO.puts("")
    :ok
  end

  defp print_header(model) do
    name = inspect(model)
    width = max(String.length(name) + 10, 65)
    border = String.duplicate("═", width)

    IO.puts(border)
    IO.puts(String.pad_leading(name, div(width + String.length(name), 2)))
    IO.puts(border)
    IO.puts("")
  end

  defp print_commands(model) do
    commands = model.commands() |> Model.normalize_commands()

    IO.puts("COMMANDS (#{length(commands)} total)")
    IO.puts(String.duplicate("─", 65))
    IO.puts("  Weight │ Command                    │ Semantics│ Creates Ref")
    IO.puts(String.duplicate("─", 65))

    for {weight, cmd_module} <- commands do
      name = cmd_module |> Module.split() |> List.last()
      semantics = get_semantics(cmd_module)
      creates_ref = get_creates_ref(cmd_module)

      weight_str = String.pad_leading("#{weight}", 5)
      name_str = String.pad_trailing(name, 26)
      semantics_str = String.pad_trailing("#{semantics}", 8)
      ref_str = if creates_ref, do: ":#{creates_ref}", else: "-"

      IO.puts("  #{weight_str}   │ #{name_str} │ #{semantics_str} │ #{ref_str}")
    end

    IO.puts("")
  end

  defp print_projections(model) do
    state_proj = model.command_sequence_projection()

    extra_projs =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    IO.puts("PROJECTIONS")
    IO.puts(String.duplicate("─", 65))
    IO.puts("  State:      #{inspect(state_proj)}")

    if extra_projs != [] do
      IO.puts("  Extra:      #{length(extra_projs)} projection(s)")

      for proj <- extra_projs do
        name = proj |> Module.split() |> List.last()
        IO.puts("              - #{name}")
      end
    else
      IO.puts("  Extra:      (none)")
    end

    IO.puts("")
  end

  defp print_optional_callbacks(model) do
    callbacks = [
      {:setup_once, 1, "One-time setup before all runs"},
      {:setup_each, 1, "Setup before each execution"},
      {:teardown_each, 1, "Cleanup after each execution"},
      {:teardown_once, 1, "Final cleanup after all runs"},
      {:terminate?, 3, "Custom termination condition"},
      {:injectable_events, 0, "Events from injector adapters"}
    ]

    implemented =
      Enum.filter(callbacks, fn {name, arity, _desc} ->
        function_exported?(model, name, arity)
      end)

    if implemented != [] do
      IO.puts("OPTIONAL CALLBACKS")
      IO.puts(String.duplicate("─", 65))

      for {name, arity, desc} <- implemented do
        IO.puts("  #{name}/#{arity} - #{desc}")
      end

      IO.puts("")
    end
  end

  defp print_hints(model) do
    hints = collect_hints(model)

    if hints != [] do
      IO.puts("HINTS")
      IO.puts(String.duplicate("─", 65))

      for hint <- hints do
        IO.puts("  #{hint}")
      end

      IO.puts("")
    end
  end

  defp collect_hints(model) do
    hints = []

    # Check for missing terminate?
    commands = model.commands() |> Model.normalize_commands()

    has_destructive =
      Enum.any?(commands, fn {_, cmd} ->
        name = cmd |> Module.split() |> List.last() |> String.downcase()
        String.contains?(name, ["delete", "close", "cancel", "destroy"])
      end)

    hints =
      if has_destructive and not function_exported?(model, :terminate?, 3) do
        ["Consider implementing terminate?/3 for destructive commands" | hints]
      else
        hints
      end

    # Check for unbalanced weights
    weights = Enum.map(commands, fn {w, _} -> w end)
    max_weight = Enum.max(weights)
    min_weight = Enum.min(weights)

    hints =
      if max_weight > min_weight * 10 do
        [
          "Large weight variance (#{min_weight}-#{max_weight}) may skew command distribution"
          | hints
        ]
      else
        hints
      end

    # Check for no probe commands
    has_probes =
      Enum.any?(commands, fn {_, cmd} ->
        get_semantics(cmd) == :probe
      end)

    hints =
      if not has_probes and length(commands) > 3 do
        ["Consider adding probe (read-only) commands for better test coverage" | hints]
      else
        hints
      end

    Enum.reverse(hints)
  end

  defp get_semantics(cmd_module) do
    if function_exported?(cmd_module, :semantics, 0) do
      cmd_module.semantics()
    else
      :sync
    end
  end

  defp get_creates_ref(cmd_module) do
    if function_exported?(cmd_module, :creates_ref, 0) do
      cmd_module.creates_ref()
    else
      nil
    end
  end

  # ============================================================================
  # dry_run/2 - Sequence Generation Preview
  # ============================================================================

  @doc """
  Generate a command sequence without executing it.

  Useful for seeing what commands would be generated given the model's
  configuration.

  ## Options

  - `:commands` - Number of commands to generate (default: 10)
  - `:seed` - Random seed for reproducibility
  - `:branching` - Enable branching sequences (default: false)
  - `:verbose` - Show detailed command fields (default: false)

  ## Examples

      iex> PropertyDamage.IEx.dry_run(MyModel, commands: 5)

      Generated sequence (5 commands):
      ─────────────────────────────────────────────────────────────────
      [0] CreateAccount{currency: "USD"}
      [1] Credit{account_ref: :ref0, amount: 500}
      [2] CreateAuthorization{account_ref: :ref0, amount: 200}
      [3] Debit{account_ref: :ref0, amount: 100}
      [4] GetBalance{account_ref: :ref0}

      Refs created: [:ref0] → CreateAccount

      Seed: 12345 (use this to reproduce)

      iex> PropertyDamage.IEx.dry_run(MyModel, seed: 12345)
      # Same sequence as above

  """
  @spec dry_run(module(), keyword()) :: :ok
  def dry_run(model, opts \\ []) do
    max_commands = Keyword.get(opts, :commands, 10)
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000_000))
    branching = Keyword.get(opts, :branching, nil)
    verbose = Keyword.get(opts, :verbose, false)

    # Generate sequence (explicitly seeded; matches what run/1 generates
    # for run 0 of the same seed)
    generator_opts = [max_commands: max_commands]

    generator_opts =
      if branching, do: Keyword.put(generator_opts, :branching, branching), else: generator_opts

    generator = Generator.generate_sequence(model, generator_opts)
    sequence = Generator.generate_value(generator, seed) || Sequence.linear([])

    # Print sequence
    IO.puts("")
    print_sequence(sequence, verbose)
    print_refs_summary(sequence)
    IO.puts("Seed: #{seed} (use this to reproduce)")
    IO.puts("")

    :ok
  end

  defp print_sequence(%Sequence{branches: nil} = seq, verbose) do
    commands = seq.prefix
    IO.puts("Generated sequence (#{length(commands)} commands):")
    IO.puts(String.duplicate("─", 65))

    commands
    |> Enum.with_index()
    |> Enum.each(fn {cmd, idx} ->
      print_command(cmd, idx, verbose)
    end)

    IO.puts("")
  end

  defp print_sequence(%Sequence{} = seq, verbose) do
    total = Sequence.command_count(seq)
    branch_count = length(seq.branches)

    IO.puts("Generated branching sequence (#{total} commands, #{branch_count} branches):")
    IO.puts(String.duplicate("─", 65))

    # Print prefix
    if seq.prefix != [] do
      IO.puts("PREFIX:")

      seq.prefix
      |> Enum.with_index()
      |> Enum.each(fn {cmd, idx} ->
        print_command(cmd, idx, verbose, "  ")
      end)
    end

    # Print branches
    IO.puts("BRANCHES:")

    seq.branches
    |> Enum.with_index()
    |> Enum.each(fn {branch, branch_idx} ->
      IO.puts("  Branch #{branch_idx + 1}:")

      branch
      |> Enum.with_index()
      |> Enum.each(fn {cmd, cmd_idx} ->
        print_command(cmd, cmd_idx, verbose, "    ")
      end)
    end)

    # Print suffix
    if seq.suffix != [] do
      IO.puts("SUFFIX:")
      offset = length(seq.prefix) + Enum.sum(Enum.map(seq.branches, &length/1))

      seq.suffix
      |> Enum.with_index(offset)
      |> Enum.each(fn {cmd, idx} ->
        print_command(cmd, idx, verbose, "  ")
      end)
    end

    IO.puts("")
  end

  defp print_command(cmd, idx, verbose, prefix \\ "") do
    cmd_name = cmd.__struct__ |> Module.split() |> List.last()
    fields = Map.from_struct(cmd) |> Map.drop([:__struct__])

    if verbose do
      IO.puts("#{prefix}[#{idx}] #{cmd_name}")

      for {key, value} <- fields do
        IO.puts("#{prefix}     #{key}: #{inspect(value)}")
      end
    else
      # Compact format: show key fields inline
      fields_str = format_fields_compact(fields)
      IO.puts("#{prefix}[#{idx}] #{cmd_name}{#{fields_str}}")
    end
  end

  defp format_fields_compact(fields) do
    fields
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> String.slice(0, 50)
    |> then(fn s ->
      if String.length(s) == 50, do: s <> "...", else: s
    end)
  end

  defp print_refs_summary(sequence) do
    commands = Sequence.to_list(sequence)

    refs_created =
      commands
      |> Enum.with_index()
      |> Enum.filter(fn {cmd, _idx} ->
        mod = cmd.__struct__

        if function_exported?(mod, :creates_ref, 0) do
          mod.creates_ref() != nil
        else
          false
        end
      end)
      |> Enum.map(fn {cmd, idx} ->
        mod = cmd.__struct__
        ref = mod.creates_ref()
        cmd_name = mod |> Module.split() |> List.last()
        ":ref#{idx} → #{cmd_name} (#{ref})"
      end)

    if refs_created != [] do
      IO.puts("Refs created:")

      for ref_info <- refs_created do
        IO.puts("  #{ref_info}")
      end

      IO.puts("")
    end
  end

  # ============================================================================
  # debug_command/3 - Single Command Execution
  # ============================================================================

  @doc """
  Execute a single command against an adapter with detailed output.

  Shows the command, request/response details, and resulting events.
  Useful for testing individual commands before running full sequences.

  ## Options

  - `:adapter_opts` - Options passed to adapter.setup/1 (default: [])
  - `:refs` - Map of ref atoms to resolved values (default: %{})

  ## Examples

      iex> PropertyDamage.IEx.debug_command(
      ...>   %CreateAccount{currency: "USD"},
      ...>   MyAdapter
      ...> )

      ═══════════════════════════════════════════════════════════════
                           COMMAND EXECUTION
      ═══════════════════════════════════════════════════════════════

      COMMAND
      ─────────────────────────────────────────────────────────────────
      CreateAccount
        currency: "USD"

      EXECUTION
      ─────────────────────────────────────────────────────────────────
      Status: OK
      Time: 15ms

      RESULT EVENT
      ─────────────────────────────────────────────────────────────────
      AccountCreated
        account_id: "acc_abc123"
        currency: "USD"
        balance: 0

      iex> PropertyDamage.IEx.debug_command(
      ...>   %Credit{account_ref: :ref0, amount: 500},
      ...>   MyAdapter,
      ...>   refs: %{ref0: "acc_abc123"}
      ...> )

  """
  @spec debug_command(struct(), module(), keyword()) :: :ok | {:error, term()}
  def debug_command(command, adapter, opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    refs = Keyword.get(opts, :refs, %{})

    IO.puts("")
    IO.puts(String.duplicate("═", 65))
    IO.puts(String.pad_leading("COMMAND EXECUTION", 40))
    IO.puts(String.duplicate("═", 65))
    IO.puts("")

    # Print command
    print_command_detail(command, refs)

    # Setup adapter
    case adapter.setup(adapter_opts) do
      {:ok, context} ->
        try do
          # Resolve refs in command
          resolved_command = resolve_refs(command, refs)

          # Execute
          start_time = System.monotonic_time(:millisecond)
          result = adapter.execute(resolved_command, context)
          elapsed = System.monotonic_time(:millisecond) - start_time

          # Print result
          print_execution_result(result, elapsed)

          :ok
        after
          adapter.teardown(context)
        end

      {:error, reason} ->
        IO.puts("ADAPTER SETUP FAILED")
        IO.puts(String.duplicate("─", 65))
        IO.puts("Reason: #{inspect(reason)}")
        IO.puts("")
        {:error, {:setup_failed, reason}}
    end
  end

  defp print_command_detail(command, refs) do
    cmd_name = command.__struct__ |> Module.split() |> List.last()
    fields = Map.from_struct(command)

    IO.puts("COMMAND")
    IO.puts(String.duplicate("─", 65))
    IO.puts(cmd_name)

    for {key, value} <- fields do
      resolved_note =
        if is_atom(value) and Map.has_key?(refs, value) do
          " → #{inspect(refs[value])}"
        else
          ""
        end

      IO.puts("  #{key}: #{inspect(value)}#{resolved_note}")
    end

    IO.puts("")
  end

  defp print_execution_result(result, elapsed) do
    IO.puts("EXECUTION")
    IO.puts(String.duplicate("─", 65))

    case result do
      {:ok, event} ->
        IO.puts("Status: OK")
        IO.puts("Time: #{elapsed}ms")
        IO.puts("")
        print_event_detail(event)

      {:error, reason} ->
        IO.puts("Status: ERROR")
        IO.puts("Time: #{elapsed}ms")
        IO.puts("Reason: #{inspect(reason)}")
        IO.puts("")
    end
  end

  defp print_event_detail(event) do
    event_name = event.__struct__ |> Module.split() |> List.last()
    fields = Map.from_struct(event)

    IO.puts("RESULT EVENT")
    IO.puts(String.duplicate("─", 65))
    IO.puts(event_name)

    for {key, value} <- fields do
      IO.puts("  #{key}: #{inspect(value)}")
    end

    IO.puts("")
  end

  defp resolve_refs(command, refs) do
    fields = Map.from_struct(command)

    resolved_fields =
      Map.new(fields, fn {key, value} ->
        resolved_value =
          if is_atom(value) and Map.has_key?(refs, value) do
            refs[value]
          else
            value
          end

        {key, resolved_value}
      end)

    struct!(command.__struct__, resolved_fields)
  end

  # ============================================================================
  # inspect_state/2 - State Inspection
  # ============================================================================

  @doc """
  Show the projection state after applying a list of events.

  Useful for understanding how events affect model state.

  ## Examples

      iex> events = [
      ...>   %AccountCreated{account_id: "acc_1", currency: "USD"},
      ...>   %Credited{account_id: "acc_1", amount: 500}
      ...> ]
      iex> PropertyDamage.IEx.inspect_state(events, MyProjection)

      STATE AFTER 2 EVENTS
      ─────────────────────────────────────────────────────────────────
      %{
        accounts: %{
          "acc_1" => %{currency: "USD", balance: 500}
        }
      }

  """
  @spec inspect_state([struct()], module()) :: :ok
  def inspect_state(events, projection) do
    initial = projection.init()

    final_state =
      Enum.reduce(events, initial, fn event, state ->
        projection.apply(state, event)
      end)

    IO.puts("")
    IO.puts("STATE AFTER #{length(events)} EVENTS")
    IO.puts(String.duplicate("─", 65))
    IO.puts(inspect(final_state, pretty: true, limit: :infinity))
    IO.puts("")

    :ok
  end

  # ============================================================================
  # check_preconditions/2 - Precondition Analysis
  # ============================================================================

  @doc """
  Check which commands have valid preconditions in a given state.

  Useful for debugging why certain commands aren't being generated.

  ## Examples

      iex> state = %{accounts: %{}}  # Empty state
      iex> PropertyDamage.IEx.check_preconditions(state, MyModel)

      PRECONDITION CHECK
      ─────────────────────────────────────────────────────────────────
        Command                    │ Precondition │ Reason
      ─────────────────────────────────────────────────────────────────
        CreateAccount              │ ✓ VALID      │ -
        Credit                     │ ✗ INVALID    │ No accounts exist
        Debit                      │ ✗ INVALID    │ No accounts exist
        GetBalance                 │ ✗ INVALID    │ No accounts exist

  """
  @spec check_preconditions(map(), module()) :: :ok
  def check_preconditions(state, model) do
    commands = model.commands() |> Model.normalize_commands()

    IO.puts("")
    IO.puts("PRECONDITION CHECK")
    IO.puts(String.duplicate("─", 65))
    IO.puts("  Command                    │ Precondition │ Weight")
    IO.puts(String.duplicate("─", 65))

    for {weight, cmd_module} <- commands do
      name = cmd_module |> Module.split() |> List.last()
      name_str = String.pad_trailing(name, 26)

      valid? = cmd_module.precondition(state)
      status = if valid?, do: "✓ VALID  ", else: "✗ INVALID"

      IO.puts("  #{name_str} │ #{status}    │ #{weight}")
    end

    valid_count = Enum.count(commands, fn {_, cmd} -> cmd.precondition(state) end)
    IO.puts(String.duplicate("─", 65))
    IO.puts("  #{valid_count}/#{length(commands)} commands valid in current state")
    IO.puts("")

    :ok
  end
end
