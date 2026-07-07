defmodule PropertyDamage.Replay do
  @moduledoc """
  Step-by-step replay of failure sequences for debugging.

  Replay mode lets you execute a failing sequence one command at a time,
  inspecting the state after each step. This is invaluable for understanding
  exactly how the system reached the failure state.

  Replay is a thin **stepping shell over the Executor**: every command runs
  through the exact same engine path as a real run (ref/placeholder resolution,
  settle for probe/async commands, nemesis injection, injector and mock events,
  projection updates, `@trigger` assertions, and stutter). This is what makes a
  recorded failure replay to the identical step sequence and state.

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
      :ok = Replay.stop(session)                    # Release the adapter/queue

  ### Jump to Failure Point

      {:ok, session} = Replay.start(failure)
      {:ok, session, steps} = Replay.step_to(session, failure.failed_at_index)
      # Now at the exact point where the failure occurred

  ## Step Information

  Each step returns:
  - `index` - Command index in sequence
  - `command` - The command struct
  - `command_name` - Short name for display
  - `events` - Events produced by this command (in chronological order)
  - `projections` - Projection states after this command
  - `projections_before` - Projection states before this command
  - `refs` - Ref resolution map
  - `result` - `:ok`, `{:check_failed, name, exception}`, or `{:error, reason}`

  ## Limitations

  - **Branching sequences are not steppable.** Interactive stepping is linear by
    nature; the fork/merge semantics of a parallel sequence cannot be reproduced
    one command at a time. `start/2` and `run/2` return
    `{:error, :branching_replay_unsupported}` for a branching `shrunk_sequence`.
    Inspect a branching failure via the `FailureReport` fields or re-run it
    through `PropertyDamage.Executor.run/4`.
  - **Stutter config is not stored in the report.** The `FailureReport` records
    the model, adapter, and sequence, but not the `stutter:` config a run was
    given. If the original run used stutter and you want it re-applied during
    replay, pass it via `opts` (`:stutter_config`). It is deliberately not
    persisted yet: stutter is not seed-deterministic (decisions consume the
    process `:rand` stream at execution time), so persisting the config alone
    would not make replay reproduce *which* commands stuttered, and a
    `{:custom, fn}` comparison cannot survive the `[:safe]` term decode used by
    `PropertyDamage.Persistence`. Persisting it belongs with the determinism
    hardening that introduces a generation-time stutter plan; see that item in
    the project's fix checklist. (`external_markers` is not a gap: real runs
    never set it, and external paths are derived from the event struct
    definitions, which are reachable from the persisted model.)
  """

  alias PropertyDamage.{EventQueue, Failure, FailureReport, Options, Sequence}
  alias PropertyDamage.Executor.Stepping

  defstruct [
    :failure,
    :commands,
    :model,
    :adapter,
    :adapter_config,
    :event_queue,
    :adapter_context,
    :exec_state,
    :current_index,
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
          result: :ok | {:check_failed, atom(), Exception.t()} | {:error, term()}
        }

  @type t :: %__MODULE__{
          failure: FailureReport.t(),
          commands: [struct()],
          model: module(),
          adapter: module(),
          adapter_config: map(),
          event_queue: pid() | nil,
          adapter_context: map() | nil,
          exec_state: map() | nil,
          current_index: integer(),
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
  - `:stutter_config` - Stutter config to apply during replay (not stored in the report)
  - `:external_markers` - External markers to apply during replay (not stored in the report)

  ## Returns

  `{:ok, [step]}` where each step contains command, events, and state info.

  ## Example

      {:ok, steps} = PropertyDamage.replay(failure)

      # Find where things went wrong
      Enum.each(steps, fn step ->
        IO.puts("[\#{step.index}] \#{step.command_name}")
        case step.result do
          :ok -> IO.puts("  -> OK")
          {:check_failed, check, _} -> IO.puts("  -> FAILED: \#{check}")
          {:error, reason} -> IO.puts("  -> ERROR: \#{inspect(reason)}")
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

  Sets up the adapter and an event queue, then leaves the session positioned
  before the first command. Use `step/1` to advance, and `stop/1` when done to
  tear the adapter and queue down.

  ## Options

  See `run/2` for the supported options.

  ## Example

      {:ok, session} = Replay.start(failure)
      {:ok, session, step1} = Replay.step(session)
      {:ok, session, step2} = Replay.step(session)
      :ok = Replay.stop(session)
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

      branching?(FailureReport.shrunk_sequence(failure)) ->
        {:error, :branching_replay_unsupported}

      true ->
        do_start(failure, model, adapter, opts)
    end
  end

  defp do_start(failure, model, adapter, opts) do
    adapter_config = opts[:adapter_config] || %{}
    sequence = FailureReport.shrunk_sequence(failure)
    commands = Sequence.to_list(sequence)

    # Mirror the run loop: model.setup_each runs before adapter setup so the
    # SUT starts in the same per-run state the original failure observed.
    if function_exported?(model, :setup_each, 1) do
      model.setup_each(%{adapter_config: adapter_config, replay: true})
    end

    {:ok, event_queue} = EventQueue.start_link()

    case adapter.setup(adapter_config) do
      {:ok, adapter_context} ->
        exec_state =
          Stepping.init_state(model,
            event_queue: event_queue,
            stutter_config: opts[:stutter_config],
            external_markers: opts[:external_markers] || [],
            assertion_mode: :halt,
            # Seed the placeholder registry from the failing sequence (DR-021),
            # so replaying a failure whose commands consume `external()` values
            # resolves them instead of raising "Unknown placeholder".
            placeholder_registry: sequence.registry
          )

        session = %__MODULE__{
          failure: failure,
          commands: commands,
          model: model,
          adapter: adapter,
          adapter_config: adapter_config,
          event_queue: event_queue,
          adapter_context: adapter_context,
          exec_state: exec_state,
          current_index: -1,
          steps: [],
          status: :ready
        }

        {:ok, session}

      {:error, reason} ->
        EventQueue.stop(event_queue)
        {:error, {:adapter_setup_failed, reason}}
    end
  end

  @doc """
  Execute the next command in the sequence.

  ## Returns

  - `{:ok, session, step}` - Command executed; `step.result` holds the outcome,
    including `{:check_failed, ...}` / `{:error, ...}` when the command failed
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

    before_state = session.exec_state
    before_log_count = length(before_state.event_log)
    projections_before = before_state.projections

    step_context = %Stepping.Context{
      model: session.model,
      adapter: session.adapter,
      adapter_context: session.adapter_context,
      event_queue: session.event_queue
    }

    case Stepping.step(command, next_index, before_state, step_context) do
      {:ok, new_exec_state} ->
        emit_step(
          session,
          new_exec_state,
          command,
          next_index,
          before_log_count,
          projections_before,
          :ok,
          :in_progress
        )

      {:error, reason, failed_state} ->
        emit_step(
          session,
          failed_state,
          command,
          next_index,
          before_log_count,
          projections_before,
          normalize_result(reason),
          :failed
        )
    end
  end

  defp emit_step(
         session,
         exec_state,
         command,
         index,
         before_log_count,
         projections_before,
         result,
         status
       ) do
    events = events_since(exec_state.event_log, before_log_count)

    step = %{
      index: index,
      command: command,
      command_name: command_name(command),
      events: events,
      projections: exec_state.projections,
      projections_before: projections_before,
      result: result
    }

    new_session = %{
      session
      | exec_state: exec_state,
        current_index: index,
        steps: session.steps ++ [step],
        status: status
    }

    {:ok, new_session, step}
  end

  @doc """
  Execute commands up to (and including) the specified index.

  ## Returns

  - `{:ok, session, [step]}` - Commands executed; failed commands appear as
    steps whose `result` is `{:check_failed, ...}` or `{:error, ...}`
  """
  @spec step_to(t(), non_neg_integer()) :: {:ok, t(), [step()]}
  def step_to(%__MODULE__{} = session, target_index) do
    step_to_loop(session, target_index, [])
  end

  @doc """
  Get the current state of projections.
  """
  @spec current_state(t()) :: map()
  def current_state(%__MODULE__{exec_state: nil}), do: %{}
  def current_state(%__MODULE__{exec_state: exec_state}), do: exec_state.projections

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

  Stops any pollers spawned during stepping, the event queue, tears the adapter
  down, and runs `teardown_each/1` if the model defines it. Safe to call more
  than once.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = session) do
    if session.exec_state, do: Stepping.stop_pollers(session.exec_state)

    if is_pid(session.event_queue) and Process.alive?(session.event_queue) do
      EventQueue.stop(session.event_queue)
    end

    if session.adapter && session.adapter_context do
      try do
        session.adapter.teardown(session.adapter_context)
      rescue
        _ -> :ok
      end
    end

    if session.model && function_exported?(session.model, :teardown_each, 1) do
      try do
        session.model.teardown_each(%{adapter_config: session.adapter_config, replay: true})
      rescue
        _ -> :ok
      end
    end

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
      |> Enum.map_join(", ", &command_name/1)

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
    |> Enum.map_join("\n", &format_step/1)
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
        # Stop advancing once a command fails: there is nothing meaningful to
        # step past a failure in a halt-mode replay.
        if step.result == :ok do
          step_to_loop(new_session, target_index, [step | acc])
        else
          {:ok, new_session, Enum.reverse([step | acc])}
        end

      {:done, final_session} ->
        {:ok, final_session, Enum.reverse(acc)}
    end
  end

  # The executor's event_log is reverse-chronological; the entries this command
  # added sit in front. Take the new ones, drop back to chronological order, and
  # surface the bare event structs (what callers historically inspected).
  defp events_since(event_log, before_count) do
    added = length(event_log) - before_count

    event_log
    |> Enum.take(max(added, 0))
    |> Enum.reverse()
    |> Enum.map(& &1.event)
  end

  # Preserve the documented per-step `result` shape: an assertion failure (now
  # carried in a %Failure{}) surfaces as {:check_failed, name, exception} — a
  # replay-local outcome vocabulary distinct from the run-level failure_reason —
  # while everything else surfaces as {:error, reason}.
  defp normalize_result(%Failure{type: %Failure.Assertion{kind: :assertion_failed} = t}) do
    exception =
      case t.detail do
        {exception, stacktrace} when is_list(stacktrace) -> exception
        other -> other
      end

    {:check_failed, t.name, exception}
  end

  defp normalize_result(reason), do: {:error, reason}

  defp command_name(%{__struct__: mod}), do: mod |> Module.split() |> List.last()
  defp command_name(other), do: inspect(other)

  defp branching?(%Sequence{} = seq), do: not Sequence.linear?(seq)
  defp branching?(_), do: false
end
