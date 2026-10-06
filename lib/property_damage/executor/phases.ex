defmodule PropertyDamage.Executor.Phases do
  @moduledoc false
  # The setup phase and the teardown phase of one target's run.
  #
  # A model's setup commands run after the adapter's `setup/1` and the
  # `@check at: :startup` checks, before the roots; its teardown commands run
  # after the run is finalized, before the adapter's `teardown/1`. Every path
  # that executes a run uses this module for both phases, so they behave alike
  # wherever a run is executed again: `PropertyDamage.Variant` (the lockstep
  # scheduler), `PropertyDamage.Executor.run/4` (a branching run, a shrink
  # attempt, a trace capture) and `PropertyDamage.Replay`.
  #
  # The setup phase steps every setup command through `Stepping.step_setup/4`,
  # drains the event queue, and then applies the completion rule: every
  # placeholder a setup command produced must be resolved. Any failure in the
  # phase is a setup failure (`Failure.setup_failed/2`): the command could not
  # run, a check failed on a setup command's event, or a placeholder stayed
  # unresolved.
  #
  # The teardown phase steps every teardown command through
  # `Stepping.step_teardown/4`, which never fails.

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.Failure
  alias PropertyDamage.PlaceholderRegistry
  alias PropertyDamage.Sequence.Position

  @doc """
  Steps `commands` as the setup commands of the run, then drains the queue
  and applies the completion rule.

  `on_step` is called with the state after every step (a caller that tracks
  the pollers a step starts uses it) and returns the state to go on with.
  Returns `{:ok, state}` or `{:failed, failure, failed_state}`, where
  `failure` is the setup failure and `failed_state` carries no attributed
  failure index.
  """
  @spec run_setup([struct()], map(), Stepping.Context.t(), (map() -> map())) ::
          {:ok, map()} | {:failed, Failure.t(), map()}
  def run_setup(commands, state, ctx, on_step \\ & &1)

  def run_setup([], state, _ctx, _on_step), do: {:ok, state}

  def run_setup(commands, state, ctx, on_step) do
    stepped =
      commands
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, state}, fn {command, offset}, {:ok, state} ->
        case Stepping.step_setup(command, offset, state, ctx) do
          {:ok, stepped, _outcome} ->
            {:cont, {:ok, on_step.(stepped)}}

          {:error, failure, failed, outcome} ->
            reason = step_failure(commands, command, offset, failure, failed, outcome)
            {:halt, failed(reason, on_step.(failed))}
        end
      end)

    with {:ok, state} <- stepped,
         {:ok, state} <- drain(commands, state, ctx, on_step) do
      completion_rule(commands, state)
    end
  end

  @doc """
  Steps `commands` as the teardown commands of the run.

  Returns `{state, entries}`: the state after the last teardown command and
  the event-log entries the teardown commands added, in chronological order.
  """
  @spec run_teardown([struct()], map(), Stepping.Context.t()) :: {map(), [map()]}
  def run_teardown([], state, _ctx), do: {state, []}

  def run_teardown(commands, state, ctx) do
    before = length(state.event_log)

    state =
      commands
      |> Enum.with_index()
      |> Enum.reduce(state, fn {command, offset}, state ->
        {:ok, state, _outcome} = Stepping.step_teardown(command, offset, state, ctx)
        state
      end)

    entries = state.event_log |> Enum.take(length(state.event_log) - before) |> Enum.reverse()
    {state, entries}
  end

  @doc """
  A finished result whose failure belongs to a setup command (an
  `@eventually` window a setup command opened, a check on a setup command's
  event drained later) reports it as the setup failure it is, with no root
  index. Any other result is returned unchanged.
  """
  @spec attribute(map(), [struct()]) :: map()
  def attribute(%{failed_at_index: {:setup, offset}} = result, commands) do
    %{
      result
      | failed_at_index: nil,
        failure_reason: check_failure(commands, offset, result.failure_reason)
    }
  end

  def attribute(result, _commands), do: result

  @doc """
  The setup failure of a check that failed on the event of the setup command
  at `offset` (nil when the event belongs to no setup command).
  """
  @spec check_failure([struct()], non_neg_integer() | nil, Failure.t()) :: Failure.t()
  def check_failure(commands, offset, failure) do
    Failure.setup_failed(:check,
      command: command_at(commands, offset),
      setup_index: offset,
      detail: failure
    )
  end

  # What a failed setup step reports: a check that failed (on this command's
  # event, or on an earlier setup command's event the step drained) is a
  # `:check` setup failure; anything else means the command could not run.
  defp step_failure(commands, command, offset, failure, failed, outcome) do
    case {failed.async_failed_index, outcome} do
      {{:setup, attributed}, _outcome} ->
        check_failure(commands, attributed, failure)

      {:unset, {:raised, exception}} ->
        Failure.setup_failed(:command, command: command, setup_index: offset, detail: exception)

      {:unset, {:error, reason}} ->
        Failure.setup_failed(:command, command: command, setup_index: offset, detail: reason)

      {_index, _outcome} ->
        if Failure.class(failure) == :check,
          do: check_failure(commands, offset, failure),
          else:
            Failure.setup_failed(:command, command: command, setup_index: offset, detail: failure)
    end
  end

  defp drain(commands, state, ctx, on_step) do
    case Stepping.drain(state, ctx) do
      {:ok, state} ->
        {:ok, on_step.(state)}

      {:error, failure, failed} ->
        offset =
          case failed.async_failed_index do
            {:setup, offset} -> offset
            _ambient -> nil
          end

        failed(check_failure(commands, offset, failure), on_step.(failed))
    end
  end

  # Completion rule: every placeholder a setup command produces is resolved
  # once the setup commands stepped and the queue drained.
  defp completion_rule(commands, state) do
    unresolved =
      case state.placeholder_registry do
        nil ->
          []

        registry ->
          registry
          |> PlaceholderRegistry.unresolved()
          |> Enum.filter(&match?(%Position{section: :setup}, &1.position))
          |> Enum.sort_by(&{&1.position.offset, &1.event_index, &1.path})
      end

    case unresolved do
      [] ->
        {:ok, state}

      [placeholder | _] ->
        offset = placeholder.position.offset

        reason =
          Failure.setup_failed(:unresolved_placeholder,
            command: command_at(commands, offset),
            setup_index: offset,
            field: placeholder.path,
            detail: placeholder
          )

        failed(reason, state)
    end
  end

  defp failed(reason, state), do: {:failed, reason, %{state | async_failed_index: :unset}}

  defp command_at(_commands, nil), do: nil
  defp command_at(commands, offset), do: Enum.at(commands, offset)
end
