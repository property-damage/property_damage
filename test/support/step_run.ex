defmodule PropertyDamage.Test.StepRun do
  @moduledoc false
  # Runs one sequence against one adapter through the stepping seam, for the
  # tests that need a whole one-target run without the runner.
  #
  # `run/4` takes the arguments and options a one-target run takes and answers
  # `{:ok, result}`, or `{:error, reason}` when the adapter's `setup/1` fails.
  # The run is the adapter's `setup/1`, the model's startup checks, the setup
  # commands, one `Stepping.step/4` per command, the finalization, the
  # teardown commands and the adapter's `teardown/1`. It does not drain the
  # event queue after each root.
  #
  # `run_in_context/5` is the same run against an adapter context the caller
  # already set up; it leaves `teardown/1` to the caller and answers the
  # result directly.

  alias PropertyDamage.Executor.{Phases, Step, Stepping}
  alias PropertyDamage.Executor.Stepping.Context
  alias PropertyDamage.Log.Cap
  alias PropertyDamage.Sequence

  @spec run(Sequence.t() | list(), module(), module(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(sequence_or_commands, model, adapter, opts \\ []) do
    sequence = to_sequence(sequence_or_commands)
    config = Keyword.get(opts, :config, %{})
    {setup_result, setup_lines} = PropertyDamage.Log.inline(fn -> adapter.setup(config) end)

    case setup_result do
      {:ok, adapter_context} ->
        run_set_up(sequence, model, adapter, adapter_context, setup_lines, opts)

      not_set_up ->
        not_set_up
    end
  end

  @spec run_in_context(Sequence.t() | list(), module(), module(), map(), keyword()) :: map()
  def run_in_context(sequence_or_commands, model, adapter, adapter_context, opts \\ []) do
    run_body(to_sequence(sequence_or_commands), model, adapter, adapter_context, %{}, opts)
  end

  defp to_sequence(%Sequence{} = sequence), do: sequence
  defp to_sequence(commands) when is_list(commands), do: Sequence.linear(commands)

  defp run_set_up(sequence, model, adapter, adapter_context, setup_lines, opts) do
    teardown_ctx = %Context{model: model, adapter: adapter, adapter_context: adapter_context}
    logs = PropertyDamage.Log.append(%{}, :adapter_setup, setup_lines)

    result =
      try do
        run_body(sequence, model, adapter, adapter_context, logs, opts)
      catch
        kind, reason ->
          Step.teardown_adapter(teardown_ctx)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    teardown_lines = Step.teardown_adapter(teardown_ctx)

    {:ok,
     %{result | logs: PropertyDamage.Log.append(result.logs, :adapter_teardown, teardown_lines)}}
  end

  defp run_body(sequence, model, adapter, adapter_context, logs, opts) do
    telemetry = Keyword.get(opts, :telemetry)
    event_queue = Keyword.get(opts, :event_queue)
    setup_commands = Keyword.get(opts, :setup_commands, [])
    teardown_commands = Keyword.get(opts, :teardown_commands, [])

    initial_state =
      model
      |> Stepping.init_state(
        event_queue: event_queue,
        stutter_config: Keyword.get(opts, :stutter_config),
        step_observer: Keyword.get(opts, :step_observer),
        check_mode: Keyword.get(opts, :check_mode, :halt),
        external_markers: Keyword.get(opts, :external_markers, []),
        placeholder_registry: sequence.registry,
        rng_seed: Keyword.get(opts, :rng_seed),
        run_nonce: Keyword.get(opts, :run_nonce),
        mint_epoch: Keyword.get(opts, :mint_epoch, 0),
        telemetry: telemetry
      )
      |> Map.merge(%{
        logs: logs,
        keep_attempts: Keyword.get(opts, :keep_attempts, Cap.default_keep_attempts())
      })

    ctx = %Context{
      model: model,
      adapter: adapter,
      adapter_context: adapter_context,
      event_queue: event_queue,
      target_name: telemetry && telemetry.variant.name
    }

    ended =
      with {:ok, state} <- Step.run_startup_checks(initial_state),
           {:ok, state} <- Phases.run_setup(setup_commands, state, ctx) do
        step_sequence(sequence, state, ctx)
      else
        {:failed, nil, _failure, _state} = failed -> failed
        {:failed, failure, failed_state} -> {:failed, nil, failure, failed_state}
      end

    result = finalize_or_tear_down(ended, setup_commands, teardown_commands, ctx)
    {state, entries} = Phases.run_teardown(teardown_commands, ended_state(ended), ctx)

    %{
      result
      | event_log: result.event_log ++ entries,
        logs: PropertyDamage.Log.merge(result.logs, state.logs)
    }
  end

  defp step_sequence(sequence, state, ctx) do
    sequence
    |> Sequence.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(state, fn {command, index}, state ->
      case Stepping.step(command, index, state, ctx) do
        {:ok, new_state, _outcome} ->
          {:cont, new_state}

        {:error, reason, failed_state, _outcome} ->
          {:halt, {:failed, index, reason, failed_state}}
      end
    end)
  end

  # A raise, throw or exit during finalization still runs the teardown
  # commands before it propagates.
  defp finalize_or_tear_down(ended, setup_commands, teardown_commands, ctx) do
    ended
    |> Stepping.finalize(ctx)
    |> Phases.attribute(setup_commands)
  catch
    kind, reason ->
      Phases.run_teardown(teardown_commands, ended_state(ended), ctx)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp ended_state({:failed, _index, _reason, state}), do: state
  defp ended_state(state), do: state
end
