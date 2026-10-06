defmodule PropertyDamage.Telemetry do
  @moduledoc """
  Telemetry events for PropertyDamage test runs.

  PropertyDamage emits telemetry events during test execution that can be
  used for monitoring, dashboards, and observability.

  ## Events

  All events are prefixed with `[:property_damage, ...]`.

  ### Run Lifecycle

  - `[:property_damage, :run, :start]` - Test run started
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{model: module(), targets: [target()], max_runs: integer(), max_commands: integer(), seed: integer()}`,
      where each `target()` is `%{index: non_neg_integer(), name: String.t(), adapter: module()}`
      (the run's `targets:` in order, the reference first)

  - `[:property_damage, :run, :stop]` - Test run completed
    - Measurements: `%{duration: integer(), total_commands: integer()}`
    - Metadata: `%{model: module(), targets: [target()], result: :ok | :error, runs_completed: integer()}`

  - `[:property_damage, :run, :exception]` - Test run crashed
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{model: module(), targets: [target()], kind: atom(), reason: term(), stacktrace: list()}`

  ### Sequence Execution

  - `[:property_damage, :sequence, :start]` - Sequence execution started
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{run_number: integer(), command_count: integer(), branching: boolean()}`

  - `[:property_damage, :sequence, :stop]` - Sequence execution completed
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{run_number: integer(), success: boolean(), commands_executed: integer(), variant: variant() | nil}`,
      one event per run; `variant` names the target the run failed in, `nil` when it passed

  ### Command Execution

  The engine emits these around every command a target executes, in the
  process that runs the target (each target of a run has its own). Shrink
  attempts and the reproduction of a failure execute commands too and emit
  them as well, with the `run_number` of that re-execution (`0`).

  - `[:property_damage, :command, :start]` - Command execution started
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{command: module(), index: integer(), run_number: integer(), variant: variant()}`

  - `[:property_damage, :command, :stop]` - Command execution completed
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{command: module(), index: integer(), run_number: integer(), variant: variant(), success: boolean(), events_count: integer()}`

  `command` is the command's module, `index` its position in the sequence (for
  a branching sequence, the index within its prefix, branch or suffix), and
  `success` whether the command completed (its adapter call, events and checks)
  without failing the run. `variant()` is `%{index: non_neg_integer(), name: String.t()}`,
  the target's position in `targets:` and its name (`index: 0` with one target).

  ### Check Execution

  The engine emits these around every evaluation of a `@check` (per command,
  per event, and at the `:startup` and `:teardown` phases). `@eventually`
  checks are polled in their own processes and emit nothing.

  - `[:property_damage, :check, :start]` - Check evaluation started
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{check_name: atom(), projection: module(), variant: variant(), run_number: integer()}`

  - `[:property_damage, :check, :stop]` - Check evaluation completed
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{check_name: atom(), projection: module(), variant: variant(), run_number: integer(), passed: boolean(), message: String.t() | nil}`

  Whether anything listens for command and check events is decided once per
  target per run, when the target starts executing: a handler attached later
  sees the next run's events.

  ### Shrinking

  - `[:property_damage, :shrink, :start]` - Shrinking started
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{original_length: integer()}`

  - `[:property_damage, :shrink, :iteration]` - Shrink iteration completed
    - Measurements: `%{iteration: integer()}`
    - Metadata: `%{current_length: integer(), success: boolean()}`

  - `[:property_damage, :shrink, :stop]` - Shrinking completed
    - Measurements: `%{duration: integer(), iterations: integer()}`
    - Metadata: `%{original_length: integer(), shrunk_length: integer()}`

  ### Progress (DR-022)

  In addition to the fine-grained spans above, every long-running operation emits
  a *coarse* progress/result heartbeat derived from the unified
  `PropertyDamage.Progress` projection. For `run/1` these are **distinct from and
  additional to** the per-unit `sequence`/`command`/`check`/`shrink` spans: the
  spans instrument each unit of work, the progress events are a campaign-level
  heartbeat.

  - `[:property_damage, :test_run, :progress]` - An intermediate run update
    - Measurements: `%{at: integer(), elapsed_ms: non_neg_integer()}`
    - Metadata: `%{data: PropertyDamage.Progress.RunUpdate.t(), run_id: term()}`

  - `[:property_damage, :test_run, :result]` - The terminal run result
    - Measurements: `%{at: integer(), elapsed_ms: non_neg_integer()}`
    - Metadata: `%{data: PropertyDamage.Progress.RunResult.t(), run_id: term()}`

  - `[:property_damage, :load_test, :progress]` - A load-test metrics snapshot
    - Measurements: `%{at: integer(), elapsed_ms: non_neg_integer()}`
    - Metadata: `%{data: PropertyDamage.Progress.LoadUpdate.t(), run_id: term()}`

  - `[:property_damage, :load_test, :result]` - The terminal load-test report
    - Measurements: `%{at: integer(), elapsed_ms: non_neg_integer()}`
    - Metadata: `%{data: PropertyDamage.Progress.LoadResult.t(), run_id: term()}`

  - `[:property_damage, :mutation, :progress]` - A per-mutation update
    - Measurements: `%{at: integer(), elapsed_ms: non_neg_integer()}`
    - Metadata: `%{data: PropertyDamage.Progress.MutationUpdate.t(), run_id: term()}`

  - `[:property_damage, :mutation, :result]` - The terminal mutation report
    - Measurements: `%{at: integer(), elapsed_ms: non_neg_integer()}`
    - Metadata: `%{data: PropertyDamage.Progress.MutationResult.t(), run_id: term()}`

  These events fire only when a handler is attached for them, preserving the
  zero-cost-when-unobserved guarantee on the hot loop.

  ## Usage

  Attach handlers using `:telemetry.attach/4`:

      :telemetry.attach(
        "my-handler",
        [:property_damage, :run, :stop],
        &MyModule.handle_event/4,
        nil
      )

  For a live in-memory rollup of these events, `PropertyDamage.Telemetry.Collector`
  subscribes to them and maintains run/command/check counters you can read or push
  to your own dashboard; the framework does not ship a renderer, so bring your own
  (Phoenix LiveView, an IEx loop, an exporter, etc.).
  """

  alias PropertyDamage.Progress

  @doc """
  Build a telemetry consumer for the unified progress projection (DR-022), or
  `nil` when nothing is listening.

  Given the operations to cover (e.g. `[:test_run]`), it checks whether a handler
  is attached for any of their `:progress`/`:result` events. If so it returns a
  `(PropertyDamage.Progress.t -> :ok)` that emits the corresponding coarse event;
  otherwise it returns `nil` so the reporter stays inert and the hot loop builds
  no `%Progress{}` (the zero-cost guarantee).
  """
  @spec progress_consumer([atom()]) :: (Progress.t() -> :ok) | nil
  def progress_consumer(operations) when is_list(operations) do
    events = for op <- operations, kind <- [:progress, :result], do: [:property_damage, op, kind]

    if Enum.any?(events, fn event -> :telemetry.list_handlers(event) != [] end) do
      &emit_progress/1
    end
  end

  defp emit_progress(%Progress{} = progress) do
    :telemetry.execute(
      Progress.telemetry_event(progress),
      %{at: progress.at || 0, elapsed_ms: progress.elapsed_ms || 0},
      %{data: progress.data, run_id: progress.run_id}
    )
  end

  @command_and_check_events [
    [:property_damage, :command, :start],
    [:property_damage, :command, :stop],
    [:property_damage, :check, :start],
    [:property_damage, :check, :stop]
  ]

  @doc false
  # The context the engine emits command and check events with, for one
  # target's run: `%{variant: variant, run_number: run_number}`, or `nil` when
  # no handler is attached to any command or check event. A `nil` context keeps
  # the per-command and per-check paths free of telemetry work.
  @spec engine_context(%{index: non_neg_integer(), name: String.t()}, non_neg_integer()) ::
          %{variant: map(), run_number: non_neg_integer()} | nil
  def engine_context(variant, run_number) do
    if Enum.any?(@command_and_check_events, &(:telemetry.list_handlers(&1) != [])) do
      %{variant: variant, run_number: run_number}
    end
  end

  @doc false
  # Runs one command for the engine inside a command start/stop pair when
  # `context` is set. `fun` returns the engine's step result; its `{:ok, _,
  # {:ok, events}}` shape counts the events.
  @spec command_span(map() | nil, term(), non_neg_integer(), (-> result)) :: result
        when result: term()
  def command_span(nil, _command, _index, fun), do: fun.()

  def command_span(context, command, index, fun) do
    metadata = %{
      command: command_module(command),
      index: index,
      run_number: context.run_number,
      variant: context.variant
    }

    start_time = System.system_time()
    command_start(metadata)
    result = fun.()

    {success, events_count} =
      case result do
        {:ok, _state, {:ok, events}} when is_list(events) -> {true, length(events)}
        {:ok, _state, _outcome} -> {true, 0}
        _failed -> {false, 0}
      end

    command_stop(start_time, Map.merge(metadata, %{success: success, events_count: events_count}))
    result
  end

  defp command_module(%{__struct__: module}), do: module
  defp command_module(command), do: command

  @doc false
  # Evaluates one check for the engine inside a check start/stop pair when
  # `context` is set. `fun` raises when the check fails; the raise is caught and
  # returned as `{:raised, exception, stacktrace}`, a pass as `:ok`.
  @spec check_span(map() | nil, module(), atom(), (-> term())) ::
          :ok | {:raised, Exception.t(), list()}
  def check_span(context, projection, check_name, fun) do
    metadata =
      context &&
        %{
          check_name: check_name,
          projection: projection,
          variant: context.variant,
          run_number: context.run_number
        }

    start_time = if metadata, do: System.system_time()
    if metadata, do: check_start(metadata)

    result =
      try do
        fun.()
        :ok
      rescue
        exception -> {:raised, exception, __STACKTRACE__}
      end

    if metadata do
      {passed, message} =
        case result do
          :ok -> {true, nil}
          {:raised, exception, _stacktrace} -> {false, Exception.message(exception)}
        end

      check_stop(start_time, Map.merge(metadata, %{passed: passed, message: message}))
    end

    result
  end

  @doc """
  Emit a run start event.
  """
  @spec run_start(map()) :: :ok
  def run_start(metadata) do
    :telemetry.execute(
      [:property_damage, :run, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emit a run stop event.
  """
  @spec run_stop(integer(), map()) :: :ok
  def run_stop(start_time, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, :run, :stop],
      %{duration: duration, total_commands: metadata[:total_commands] || 0},
      metadata
    )
  end

  @doc """
  Emit a run exception event.
  """
  @spec run_exception(integer(), atom(), term(), list(), map()) :: :ok
  def run_exception(start_time, kind, reason, stacktrace, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, :run, :exception],
      %{duration: duration},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  @doc """
  Emit a sequence start event.
  """
  @spec sequence_start(map()) :: :ok
  def sequence_start(metadata) do
    :telemetry.execute(
      [:property_damage, :sequence, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emit a sequence stop event.
  """
  @spec sequence_stop(integer(), map()) :: :ok
  def sequence_stop(start_time, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, :sequence, :stop],
      %{duration: duration},
      metadata
    )
  end

  @doc """
  Emit a command start event.
  """
  @spec command_start(map()) :: :ok
  def command_start(metadata) do
    :telemetry.execute(
      [:property_damage, :command, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emit a command stop event.
  """
  @spec command_stop(integer(), map()) :: :ok
  def command_stop(start_time, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, :command, :stop],
      %{duration: duration},
      metadata
    )
  end

  @doc """
  Emit a check start event.
  """
  @spec check_start(map()) :: :ok
  def check_start(metadata) do
    :telemetry.execute(
      [:property_damage, :check, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emit a check stop event.
  """
  @spec check_stop(integer(), map()) :: :ok
  def check_stop(start_time, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, :check, :stop],
      %{duration: duration},
      metadata
    )
  end

  @doc """
  Emit a shrink start event.
  """
  @spec shrink_start(map()) :: :ok
  def shrink_start(metadata) do
    :telemetry.execute(
      [:property_damage, :shrink, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emit a shrink iteration event.
  """
  @spec shrink_iteration(integer(), map()) :: :ok
  def shrink_iteration(iteration, metadata) do
    :telemetry.execute(
      [:property_damage, :shrink, :iteration],
      %{iteration: iteration},
      metadata
    )
  end

  @doc """
  Emit a shrink stop event.
  """
  @spec shrink_stop(integer(), map()) :: :ok
  def shrink_stop(start_time, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, :shrink, :stop],
      %{duration: duration, iterations: metadata[:iterations] || 0},
      metadata
    )
  end

  @doc """
  Execute a function with telemetry span instrumentation.

  Emits start and stop (or exception) events around the function.

  ## Examples

      Telemetry.span(:run, %{model: MyModel}, fn ->
        # run logic
        {:ok, result}
      end)
  """
  @spec span(atom(), map(), (-> result)) :: result when result: term()
  def span(event_type, metadata, fun) do
    start_time = System.system_time()
    start_fun = start_function(event_type)
    stop_fun = stop_function(event_type)

    start_fun.(metadata)

    try do
      result = fun.()
      stop_fun.(start_time, Map.put(metadata, :result, :ok))
      result
    rescue
      e ->
        emit_exception(event_type, start_time, :error, e, __STACKTRACE__, metadata)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        emit_exception(event_type, start_time, kind, reason, __STACKTRACE__, metadata)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Emit a `[:property_damage, event_type, :exception]` event. The exception
  # event must match the span's own event_type (e.g. a failing :command span
  # emits a :command exception, not a :run one).
  defp emit_exception(event_type, start_time, kind, reason, stacktrace, metadata) do
    duration = System.system_time() - start_time

    :telemetry.execute(
      [:property_damage, event_type, :exception],
      %{duration: duration},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  defp start_function(:run), do: &run_start/1
  defp start_function(:sequence), do: &sequence_start/1
  defp start_function(:command), do: &command_start/1
  defp start_function(:check), do: &check_start/1
  defp start_function(:shrink), do: &shrink_start/1

  defp stop_function(:run), do: &run_stop/2
  defp stop_function(:sequence), do: &sequence_stop/2
  defp stop_function(:command), do: &command_stop/2
  defp stop_function(:check), do: &check_stop/2
  defp stop_function(:shrink), do: &shrink_stop/2
end
