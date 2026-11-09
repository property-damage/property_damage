defmodule PropertyDamage.Executor.StepObserver do
  @moduledoc """
  A behaviour for a party that watches every step of a run and may feed
  events back into it, such as the mocked third parties of
  `PropertyDamage.MockServiceRegistry`, the first implementation.

  The executor state holds at most one observer, as `{module, observer}`,
  registered when the state is built (`step_observer:` of
  `PropertyDamage.Executor.Stepping.init_state/2`); `nil` means none. The
  executor calls the module's callbacks with `observer` at four points of a
  run:

    1. Before the adapter executes a command, `c:before_command/3`. An
       `{:error, reason}` fails the step before the adapter is called, as an
       adapter error whose detail is `reason`.
    2. After a command's own events and the queued injector events folded,
       the events the observer holds (`c:take_events/1`) fold one at a time,
       each announced to it first (`c:on_event/3`), then `c:after_fold/3`
       with `:step` and the new projections.
    3. At a drain between steps (`PropertyDamage.Executor.Stepping.drain/2`):
       the same fold, then `c:after_fold/3` with `:drain`.
    4. At finalization, after the last drain: the same fold, then
       `c:after_fold/3` with `:finalize`.

  An event the observer hands back is logged with source `:mock` and the
  index of the step it belongs to. An `{:error, reason}` from
  `c:on_event/3` stops the fold and fails that step, as an adapter error.

  The adapter's runtime handle passes through `c:runtime/2` before
  `execute/3` receives it, so the observer can hand the adapter what it
  needs to reach it.

  The `log` each callback receives writes a line under the step it is
  called for (DR-054), or is `nil` when there is none.
  """

  alias PropertyDamage.Runtime

  @typedoc "A registered observer: its module and the term handed to each callback."
  @type t :: {module(), term()} | nil

  @typedoc "A log writer for the step a callback runs for, or `nil`."
  @type log :: (term(), keyword() -> :ok) | nil

  @typedoc "The point of the run an `c:after_fold/3` call follows."
  @type point :: :step | :drain | :finalize

  @doc "Called with a command before the adapter executes it."
  @callback before_command(observer :: term(), command :: struct() | map(), log()) ::
              :ok | {:error, term()}

  @doc "Returns the events the observer holds for the run, and forgets them."
  @callback take_events(observer :: term()) :: [struct()]

  @doc "Called with each event `c:take_events/1` returned, before it folds."
  @callback on_event(observer :: term(), event :: struct(), log()) :: :ok | {:error, term()}

  @doc "Called with the projections after the observer's events folded at `point`."
  @callback after_fold(observer :: term(), projections :: map(), point()) :: :ok

  @doc "Returns the runtime handle `execute/3` receives for a command."
  @callback runtime(observer :: term(), Runtime.t()) :: Runtime.t()

  @doc "Calls `c:before_command/3` of the registered observer; `:ok` for none."
  @spec before_command(t(), struct() | map(), log()) :: :ok | {:error, term()}
  def before_command(nil, _command, _log), do: :ok

  def before_command({module, observer}, command, log),
    do: module.before_command(observer, command, log)

  @doc "Calls `c:take_events/1` of the registered observer; `[]` for none."
  @spec take_events(t()) :: [struct()]
  def take_events(nil), do: []
  def take_events({module, observer}), do: module.take_events(observer)

  @doc "Calls `c:on_event/3` of the registered observer; `:ok` for none."
  @spec on_event(t(), struct(), log()) :: :ok | {:error, term()}
  def on_event(nil, _event, _log), do: :ok
  def on_event({module, observer}, event, log), do: module.on_event(observer, event, log)

  @doc "Calls `c:after_fold/3` of the registered observer; `:ok` for none."
  @spec after_fold(t(), map(), point()) :: :ok
  def after_fold(nil, _projections, _point), do: :ok

  def after_fold({module, observer}, projections, point),
    do: module.after_fold(observer, projections, point)

  @doc "Calls `c:runtime/2` of the registered observer; `runtime` unchanged for none."
  @spec runtime(t(), Runtime.t()) :: Runtime.t()
  def runtime(nil, runtime), do: runtime
  def runtime({module, observer}, runtime), do: module.runtime(observer, runtime)
end
