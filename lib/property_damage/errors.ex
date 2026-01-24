defmodule PropertyDamage.Errors do
  @moduledoc """
  User-friendly error messages with hints for common mistakes.

  This module provides clear, actionable error messages that help users
  diagnose and fix configuration problems quickly.

  ## Usage

  These functions are called internally by PropertyDamage when errors occur.
  They format errors with:
  - Clear description of what went wrong
  - Context about where/when it happened
  - Hint suggesting how to fix it

  ## Example Output

      ERROR: Precondition returned false for Credit

      Context: Generating command at position 3
      State: %{accounts: %{}}

      Hint: Credit requires at least one account to exist.
            The precondition checks: map_size(state.accounts) > 0

            Did you forget to include CreateAccount in your model's commands?
  """

  # ============================================================================
  # Precondition Errors
  # ============================================================================

  @doc """
  Format an error when no commands have valid preconditions.
  """
  def no_valid_commands(model, state) do
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()
    command_names = Enum.map(commands, fn {_, cmd} -> format_module(cmd) end)

    """

    ERROR: No commands have valid preconditions

    Available commands: #{Enum.join(command_names, ", ")}
    Current state: #{inspect(state, pretty: true, limit: 5)}

    Hint: All command preconditions returned false for the current state.
          This usually means:
          1. The model needs "seed" commands that are always valid (like CreateEntity)
          2. A precondition is too restrictive
          3. The state projection isn't tracking entities correctly

          Check your commands' precondition/1 callbacks.
    """
  end

  @doc """
  Format an error when a specific command's precondition fails unexpectedly.
  """
  def precondition_failed(command_module, state, context \\ %{}) do
    cmd_name = format_module(command_module)
    position = Map.get(context, :position, "unknown")

    precondition_hint = infer_precondition_hint(command_module, state)

    """

    ERROR: Precondition returned false for #{cmd_name}

    Context: Generating command at position #{position}
    State keys: #{inspect(Map.keys(state))}

    #{precondition_hint}
    """
  end

  defp infer_precondition_hint(command_module, state) do
    cmd_name = format_module(command_module)
    state_info = summarize_state(state)

    """
    Hint: #{cmd_name} precondition check failed.
          #{state_info}

          Common fixes:
          - Ensure prerequisite entities exist before this command
          - Check that your state projection is updating correctly
          - Verify the precondition logic matches your intent
    """
  end

  defp summarize_state(state) when is_map(state) do
    summaries =
      state
      |> Enum.filter(fn {_k, v} -> is_map(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{map_size(v)} items" end)

    if length(summaries) > 0 do
      "Current state has: #{Enum.join(summaries, ", ")}"
    else
      "State appears empty or has no map fields"
    end
  end

  defp summarize_state(_), do: "State is not a map"

  # ============================================================================
  # Module/Callback Errors
  # ============================================================================

  @doc """
  Format an error when a required module doesn't exist.
  """
  def module_not_found(module, role) do
    mod_name = format_module(module)

    hint =
      case role do
        :model ->
          """
          Hint: The model module defines your test configuration.
                Make sure the module is defined and the code is compiled.

                Example model:
                  defmodule #{mod_name} do
                    @behaviour PropertyDamage.Model

                    def commands, do: [CreateEntity, UpdateEntity]
                    def command_sequence_projection, do: MyProjection
                    def assertion_projections, do: [MyInvariant]
                  end
          """

        :adapter ->
          """
          Hint: The adapter module connects PropertyDamage to your system.
                Make sure the module is defined and the code is compiled.

                Example adapter:
                  defmodule #{mod_name} do
                    @behaviour PropertyDamage.Adapter

                    def setup(opts), do: {:ok, %{}}
                    def teardown(ctx), do: :ok
                    def execute(cmd, ctx), do: {:ok, %SomeEvent{}}
                  end
          """

        :command ->
          """
          Hint: Command modules define operations that can be generated.
                Make sure the module is defined and the code is compiled.

                Example command:
                  defmodule #{mod_name} do
                    @behaviour PropertyDamage.Command

                    defstruct [:field1, :field2]

                    def precondition(_state), do: true
                    def new!(state, overrides), do: StreamData.constant(%__MODULE__{})
                  end
          """

        :projection ->
          """
          Hint: Projection modules track state or check invariants.
                Make sure the module is defined and the code is compiled.

                Example projection:
                  defmodule #{mod_name} do
                    @behaviour PropertyDamage.Model.Projection

                    def init, do: %{}
                    def apply(state, event), do: state
                  end
          """

        _ ->
          "Hint: Make sure the module is defined and the code is compiled."
      end

    """

    ERROR: Module #{mod_name} does not exist

    Role: #{role}

    #{hint}
    """
  end

  @doc """
  Format an error when a required callback is missing.
  """
  def callback_missing(module, callback, arity, role) do
    mod_name = format_module(module)

    example =
      case {role, callback, arity} do
        {:command, :precondition, 1} ->
          """
          def precondition(state) do
            # Return true if this command can be generated in current state
            true
          end
          """

        {:command, :new!, 2} ->
          """
          def new!(state, overrides) do
            # Return a StreamData generator for this command
            StreamData.constant(%__MODULE__{})
          end
          """

        {:model, :commands, 0} ->
          """
          def commands do
            # Return list of command modules (optionally weighted)
            [{3, CreateEntity}, {1, DeleteEntity}]
          end
          """

        {:model, :command_sequence_projection, 0} ->
          """
          def command_sequence_projection do
            # Return the projection module for tracking state
            MyProjection
          end
          """

        {:model, :assertion_projections, 0} ->
          """
          def assertion_projections do
            # Return list of extra projection modules (optional)
            [MyInvariant]
          end
          """

        {:adapter, :setup, 1} ->
          """
          def setup(opts) do
            # Initialize adapter, return context
            {:ok, %{}}
          end
          """

        {:adapter, :execute, 2} ->
          """
          def execute(command, context) do
            # Execute command, return event
            {:ok, %SomeEvent{}}
          end
          """

        {:projection, :init, 0} ->
          """
          def init do
            # Return initial state
            %{}
          end
          """

        {:projection, :apply, 2} ->
          """
          def apply(state, event) do
            # Update state based on event
            state
          end
          """

        _ ->
          "def #{callback}(...), do: ..."
      end

    """

    ERROR: #{mod_name} is missing required callback #{callback}/#{arity}

    Add this callback to your module:

        #{String.trim(example)}

    """
  end

  # ============================================================================
  # Execution Errors
  # ============================================================================

  @doc """
  Format an error when adapter setup fails.
  """
  def adapter_setup_failed(adapter, reason) do
    adapter_name = format_module(adapter)

    """

    ERROR: Adapter setup failed

    Adapter: #{adapter_name}
    Reason: #{inspect(reason)}

    Hint: The adapter's setup/1 callback returned {:error, ...}.
          Common causes:
          - Server not running (check if your SUT is started)
          - Wrong URL or port in adapter config
          - Missing configuration options

          Check your adapter's setup/1 implementation.
    """
  end

  @doc """
  Format an error when command execution fails.
  """
  def execution_failed(command, reason, context \\ %{}) do
    cmd_name = command.__struct__ |> format_module()
    position = Map.get(context, :position, "unknown")

    """

    ERROR: Command execution failed

    Command: #{cmd_name}
    Position: #{position}
    Reason: #{inspect(reason)}

    Hint: The adapter's execute/2 returned {:error, ...}.
          This indicates an infrastructure failure, not a business logic error.

          Common causes:
          - Network timeout or connection refused
          - Server returned unexpected response
          - Unhandled exception in adapter

          For expected failures (like validation errors), return {:ok, %FailureEvent{}}
          instead of {:error, ...}.
    """
  end

  @doc """
  Format an error when an invariant is violated.
  """
  def invariant_violated(projection, message, context \\ %{}) do
    proj_name = format_module(projection)
    command = Map.get(context, :command)
    position = Map.get(context, :position, "unknown")

    cmd_info =
      if command do
        cmd_name = command.__struct__ |> format_module()
        "After command: #{cmd_name} at position #{position}"
      else
        "Position: #{position}"
      end

    """

    INVARIANT VIOLATED: #{proj_name}

    #{message}

    #{cmd_info}

    Hint: An assertion projection's check/1 returned {:violated, ...}.
          This means your system is in a state that shouldn't be possible.

          This is likely a real bug! Examine:
          - The command that triggered this violation
          - The sequence of commands leading up to it
          - Whether your invariant accurately describes the requirement
    """
  end

  # ============================================================================
  # Ref Errors
  # ============================================================================

  @doc """
  Format an error when a ref cannot be resolved.
  """
  def unresolved_ref(ref, available_refs) do
    available_str =
      if length(available_refs) > 0 do
        Enum.join(available_refs, ", ")
      else
        "(none)"
      end

    """

    ERROR: Cannot resolve ref #{inspect(ref)}

    Available refs: #{available_str}

    Hint: The command references an entity that doesn't exist.
          This usually means:
          1. The command's refs_used/2 declares a ref that wasn't created
          2. The precondition allows this command when it shouldn't
          3. A previous command failed to create the expected ref

          Check that:
          - Your command's precondition ensures required entities exist
          - Your refs_used/2 returns refs from command fields
          - Previous commands in the sequence created the required refs
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_module(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp format_module(other), do: inspect(other)
end
