defmodule PropertyDamage.Replay do
  @moduledoc """
  Step-by-step replay of failure sequences for debugging.

  Replay mode lets you execute a failing sequence one command at a time,
  inspecting the state after each step. This is invaluable for understanding
  exactly how the system reached the failure state.

  ## Usage Modes

  ### Functional Mode (Recommended for scripts)

      # Get all steps at once
      {:ok, steps} = PropertyDamage.replay(failure)
      for step <- steps do
        IO.puts("Command \#{step.index}: \#{step.command_name}")
        IO.inspect(step.projections, label: "State")
      end

  ### Interactive Mode (For LiveBook/IEx)

      {:ok, session} = Replay.start(failure)
      {:ok, session, step} = Replay.step(session)  # Execute first command
      IO.inspect(step.projections)                  # Inspect state
      {:ok, session, step} = Replay.step(session)  # Next command
      # ...continue stepping...

  ### Jump to Failure Point

      {:ok, session} = Replay.start(failure)
      {:ok, session, steps} = Replay.step_to(session, failure.failed_at_index)
      # Now at the exact point where the failure occurred

  ## Step Information

  Each step returns:
  - `index` - Command index in sequence
  - `command` - The command struct
  - `command_name` - Short name for display
  - `events` - Events produced by this command
  - `projections` - Projection states after this command
  - `refs` - Ref resolution map
  - `result` - `:ok`, `{:check_failed, ...}`, or error
  """

  alias PropertyDamage.{FailureReport, Sequence, EventQueue, Ref, Options}

  defstruct [
    :failure,
    :commands,
    :model,
    :adapter,
    :adapter_config,
    :event_queue,
    :current_index,
    :projections,
    :refs,
    :event_log,
    :steps,
    :status
  ]

  @type step :: %{
          index: non_neg_integer(),
          command: struct(),
          command_name: String.t(),
          events: [struct()],
          projections: map(),
          projections_before: map(),
          refs: map(),
          result: :ok | {:check_failed, atom(), String.t()} | {:error, term()}
        }

  @type t :: %__MODULE__{
          failure: FailureReport.t(),
          commands: [struct()],
          model: module(),
          adapter: module(),
          adapter_config: map(),
          event_queue: pid(),
          current_index: integer(),
          projections: map(),
          refs: map(),
          event_log: [term()],
          steps: [step()],
          status: :ready | :in_progress | :completed | :failed
        }

  # ============================================================================
  # Functional API
  # ============================================================================

  @doc """
  Replay an entire failure sequence, returning all steps.

  This is the simplest way to replay - it executes all commands and
  returns structured information about each step.

  ## Options

  - `:adapter_config` - Override adapter configuration
  - `:stop_on_failure` - Stop at first failure (default: true)
  - `:include_projections` - Include projection states (default: true)

  ## Returns

  `{:ok, [step]}` where each step contains command, events, and state info.

  ## Example

      {:ok, steps} = PropertyDamage.replay(failure)

      # Find where things went wrong
      Enum.each(steps, fn step ->
        IO.puts("[\#{step.index}] \#{step.command_name}")
        case step.result do
          :ok -> IO.puts("  -> OK")
          {:check_failed, check, msg} -> IO.puts("  -> FAILED: \#{check} - \#{msg}")
        end
      end)
  """
  @spec run(FailureReport.t(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def run(%FailureReport{} = failure, opts \\ []) do
    opts = Options.validate_replay!(opts)

    case start(failure, opts) do
      {:ok, session} ->
        run_all_steps(session, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Start an interactive replay session.

  Use `step/1` to advance through commands one at a time.

  ## Options

  - `:adapter_config` - Override adapter configuration

  ## Example

      {:ok, session} = Replay.start(failure)
      {:ok, session, step1} = Replay.step(session)
      {:ok, session, step2} = Replay.step(session)
  """
  @spec start(FailureReport.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%FailureReport{} = failure, opts \\ []) do
    opts = Options.validate_replay!(opts)
    model = failure.model
    adapter = failure.adapter

    cond do
      is_nil(model) ->
        {:error, :missing_model}

      is_nil(adapter) ->
        {:error, :missing_adapter}

      true ->
        adapter_config = opts[:adapter_config]
        commands = Sequence.to_list(failure.shrunk_sequence)

        {:ok, event_queue} = EventQueue.start_link()

        # Initialize projections (state projection + extra projections)
        command_sequence_projection = model.command_sequence_projection()

        assertion_projections =
          if function_exported?(model, :assertion_projections, 0) do
            model.assertion_projections()
          else
            []
          end

        all_projections = [command_sequence_projection | assertion_projections]

        initial_projections =
          all_projections
          |> Enum.map(fn proj -> {proj, proj.init()} end)
          |> Map.new()

        session = %__MODULE__{
          failure: failure,
          commands: commands,
          model: model,
          adapter: adapter,
          adapter_config: adapter_config,
          event_queue: event_queue,
          current_index: -1,
          projections: initial_projections,
          refs: %{},
          event_log: [],
          steps: [],
          status: :ready
        }

        {:ok, session}
    end
  end

  @doc """
  Execute the next command in the sequence.

  ## Returns

  - `{:ok, session, step}` - Command executed; `step.result` holds the outcome,
    including `{:error, ...}` when the command itself failed
  - `{:done, session}` - No more commands to execute
  """
  @spec step(t()) :: {:ok, t(), step()} | {:done, t()}
  def step(%__MODULE__{current_index: idx, commands: commands} = session)
      when idx + 1 >= length(commands) do
    {:done, %{session | status: :completed}}
  end

  def step(%__MODULE__{} = session) do
    next_index = session.current_index + 1
    command = Enum.at(session.commands, next_index)

    # Call setup_each if this is the first command
    session =
      if next_index == 0 do
        call_setup_each(session)
      else
        session
      end

    # Resolve refs
    resolved_command = resolve_refs(command, session.refs)

    # Capture projections before
    projections_before = session.projections

    # Execute command
    case execute_command(resolved_command, session) do
      {:ok, events, response} ->
        # Update refs
        new_refs = update_refs(session.refs, command, response, next_index)

        # Apply events to projections
        new_projections = apply_events(session.projections, events)

        # Run checks
        result = run_checks(session.model, new_projections)

        # Build step info
        step = %{
          index: next_index,
          command: command,
          command_name: command.__struct__ |> Module.split() |> List.last(),
          events: events,
          projections: new_projections,
          projections_before: projections_before,
          refs: new_refs,
          result: result
        }

        new_session = %{
          session
          | current_index: next_index,
            projections: new_projections,
            refs: new_refs,
            event_log: session.event_log ++ events,
            steps: session.steps ++ [step],
            status: if(result == :ok, do: :in_progress, else: :failed)
        }

        {:ok, new_session, step}

      {:error, reason} ->
        step = %{
          index: next_index,
          command: command,
          command_name: command.__struct__ |> Module.split() |> List.last(),
          events: [],
          projections: session.projections,
          projections_before: projections_before,
          refs: session.refs,
          result: {:error, reason}
        }

        {:ok, %{session | status: :failed, steps: session.steps ++ [step]}, step}
    end
  end

  @doc """
  Execute commands up to (and including) the specified index.

  ## Returns

  - `{:ok, session, [step]}` - Commands executed; failed commands appear as
    steps whose `result` is `{:error, ...}`
  """
  @spec step_to(t(), non_neg_integer()) :: {:ok, t(), [step()]}
  def step_to(%__MODULE__{} = session, target_index) do
    step_to_loop(session, target_index, [])
  end

  @doc """
  Get the current state of projections.
  """
  @spec current_state(t()) :: map()
  def current_state(%__MODULE__{projections: projections}), do: projections

  @doc """
  Get all executed steps so far.
  """
  @spec history(t()) :: [step()]
  def history(%__MODULE__{steps: steps}), do: steps

  @doc """
  Get the command at a specific index (without executing).
  """
  @spec peek(t(), non_neg_integer()) :: {:ok, struct()} | {:error, :out_of_bounds}
  def peek(%__MODULE__{commands: commands}, index) do
    case Enum.at(commands, index) do
      nil -> {:error, :out_of_bounds}
      cmd -> {:ok, cmd}
    end
  end

  @doc """
  Clean up session resources.

  Call this when done with an interactive session.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{event_queue: eq}) when is_pid(eq) do
    EventQueue.stop(eq)
    :ok
  end

  def stop(_), do: :ok

  @doc """
  Format a step for display.
  """
  @spec format_step(step()) :: String.t()
  def format_step(step) do
    status =
      case step.result do
        :ok -> "OK"
        {:check_failed, check, _} -> "FAILED (#{check})"
        {:error, reason} -> "ERROR: #{inspect(reason)}"
      end

    events_str =
      step.events
      |> Enum.map(fn e -> e.__struct__ |> Module.split() |> List.last() end)
      |> Enum.join(", ")

    """
    [#{step.index}] #{step.command_name} -> #{status}
        Events: #{if events_str == "", do: "(none)", else: events_str}
    """
  end

  @doc """
  Format all steps for display.
  """
  @spec format_history(t() | [step()]) :: String.t()
  def format_history(%__MODULE__{steps: steps}), do: format_history(steps)

  def format_history(steps) when is_list(steps) do
    steps
    |> Enum.map(&format_step/1)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp run_all_steps(session, opts) do
    stop_on_failure = opts[:stop_on_failure]
    do_run_all_steps(session, stop_on_failure)
  end

  defp do_run_all_steps(session, stop_on_failure) do
    case step(session) do
      {:ok, new_session, step} ->
        if stop_on_failure and step.result != :ok do
          stop(new_session)
          {:ok, new_session.steps}
        else
          do_run_all_steps(new_session, stop_on_failure)
        end

      {:done, final_session} ->
        stop(final_session)
        {:ok, final_session.steps}
    end
  end

  defp step_to_loop(session, target_index, acc) when session.current_index >= target_index do
    {:ok, session, Enum.reverse(acc)}
  end

  defp step_to_loop(session, target_index, acc) do
    case step(session) do
      {:ok, new_session, step} ->
        step_to_loop(new_session, target_index, [step | acc])

      {:done, final_session} ->
        {:ok, final_session, Enum.reverse(acc)}
    end
  end

  defp call_setup_each(session) do
    if function_exported?(session.model, :setup_each, 1) do
      session.model.setup_each(%{adapter_config: session.adapter_config})
    end

    session
  end

  defp resolve_refs(command, refs) do
    deep_resolve_refs(command, refs)
  end

  defp deep_resolve_refs(%Ref{} = ref, refs) do
    case Map.get(refs, ref.ref) do
      nil -> ref
      value -> Ref.resolve(ref, value)
    end
  end

  defp deep_resolve_refs(%{__struct__: _} = struct, refs) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, deep_resolve_refs(v, refs)} end)
    |> Map.new()
    |> then(&struct(struct.__struct__, &1))
  end

  defp deep_resolve_refs(map, refs) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {deep_resolve_refs(k, refs), deep_resolve_refs(v, refs)}
    end
  end

  defp deep_resolve_refs(list, refs) when is_list(list) do
    Enum.map(list, &deep_resolve_refs(&1, refs))
  end

  defp deep_resolve_refs(tuple, refs) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> deep_resolve_refs(refs)
    |> List.to_tuple()
  end

  defp deep_resolve_refs(other, _refs), do: other

  defp execute_command(command, session) do
    try do
      response = session.adapter.execute(command, session.adapter_config)
      events = command.__struct__.events(command, response)
      {:ok, events, response}
    rescue
      e -> {:error, {:execution_error, e}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp update_refs(refs, command, response, index) do
    case command.__struct__.ref(command, response) do
      nil -> refs
      ref_value -> Map.put(refs, {:ref, index}, ref_value)
    end
  end

  defp apply_events(projections, events) do
    Enum.reduce(events, projections, fn event, projs ->
      Enum.reduce(projs, %{}, fn {proj_mod, state}, acc ->
        new_state =
          if proj_mod.handles?(event) do
            proj_mod.apply(state, event)
          else
            state
          end

        Map.put(acc, proj_mod, new_state)
      end)
    end)
  end

  defp run_checks(model, projections) do
    command_sequence_projection = model.command_sequence_projection()

    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    all_projections = [command_sequence_projection | assertion_projections]

    # Run assertions for each projection
    # Note: In replay mode, we run all assertions since we can't track step counts
    Enum.reduce_while(all_projections, :ok, fn projection, :ok ->
      projection_state = Map.get(projections, projection)

      assertions =
        if function_exported?(projection, :__assertions__, 0) do
          projection.__assertions__()
        else
          []
        end

      case run_projection_assertions(projection, projection_state, assertions) do
        :ok -> {:cont, :ok}
        {:check_failed, _, _} = error -> {:halt, error}
      end
    end)
  end

  defp run_projection_assertions(_projection, _state, []), do: :ok

  defp run_projection_assertions(projection, state, [assertion | rest]) do
    # In replay mode, run assertions with every_step trigger always
    # For other triggers (every: N, every: Module), we run them anyway
    # since replay is for debugging and should show all potential issues
    try do
      assertion_fn = assertion.function_name
      apply(projection, assertion_fn, [state, nil])
      # Success - no exception raised
      run_projection_assertions(projection, state, rest)
    rescue
      e ->
        # Assertion failed by raising exception
        {:check_failed, assertion.name, e}
    end
  end
end
