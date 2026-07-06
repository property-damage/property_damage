defmodule PropertyDamage.Executor.Timeout do
  @moduledoc false
  # Per-command adapter timeout for the core Executor (DR-032).
  #
  # `adapter.timeout/1` declares a wall-clock budget for executing a command
  # (default 30s). Before DR-032 only the load-test worker honored it; an
  # ordinary run had no bound, so a wedged `execute/3` hung forever. This module
  # wraps each `adapter.execute/3` attempt in a bounded Task and, on timeout,
  # returns a structured `CommandTimeoutError` through the normal adapter result
  # channel (`{:error, reason}`), so it flows through FailureReport/ErrorOrigin
  # exactly like any other adapter error. It does not raise, so it composes with
  # the settle retry loop (which treats `{:error, _}` as a final error, not a
  # retry) and the stutter retry path (which has no surrounding rescue).
  #
  # The Runtime.Sink lives in the parent process (execute_regular_command), and
  # the adapter's `runtime.inject` closure writes to it cross-process. A
  # timed-out Task is shut down but the sink survives, so events injected before
  # the hang are still drained by the caller.

  alias PropertyDamage.CommandTimeoutError

  @doc """
  Run `adapter.execute(command, user_context, runtime)` under the adapter's
  per-command timeout. Returns the adapter's result unchanged, or
  `{:error, %CommandTimeoutError{}}` if the timeout elapses.
  """
  @spec execute(module(), struct() | map(), term(), struct()) :: term()
  def execute(adapter, command, user_context, runtime) do
    timeout_ms = command_timeout_ms(adapter, command)

    task =
      Task.async(fn ->
        try do
          {:returned, adapter.execute(command, user_context, runtime)}
        rescue
          e -> {:raised, e, __STACKTRACE__}
        catch
          # A BEAM exit/throw from user code inside `execute/3` bypasses `rescue`
          # and would otherwise kill this Task and, through its link, the whole
          # run. Capture it here and route it through the same `{:error, _}`
          # channel a returned error uses, so the executor reports an
          # `:adapter_error` and the shrinker engages identically (A1).
          :exit, reason -> {:caught, :exit, reason}
          :throw, value -> {:caught, :throw, value}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {:returned, result}} ->
        result

      # Preserve the pre-DR-032 exception channel: a raising `execute/3` used to
      # be rescued in execute_regular_command into `{:error, {e, stacktrace}}`.
      {:ok, {:raised, exception, stacktrace}} ->
        {:error, {exception, stacktrace}}

      # An exit/throw from `execute/3` is surfaced as an ordinary adapter error
      # (tagged with how it escaped), exactly as if the adapter had returned
      # `{:error, {:exit, reason}}` / `{:error, {:throw, value}}`.
      {:ok, {:caught, kind, reason}} ->
        {:error, {kind, reason}}

      _timed_out_or_exited ->
        {:error, CommandTimeoutError.exception(command: command, timeout_ms: timeout_ms)}
    end
  end

  @doc "Resolve the adapter's `timeout/1` for a command into milliseconds."
  @spec command_timeout_ms(module(), struct() | map()) :: pos_integer()
  def command_timeout_ms(adapter, command), do: normalize_timeout(adapter.timeout(command))

  @doc "Normalize a `timeout_value/0` (bare seconds or `{n, unit}`) into milliseconds."
  @spec normalize_timeout(PropertyDamage.Adapter.timeout_value()) :: pos_integer()
  def normalize_timeout(seconds) when is_integer(seconds), do: seconds * 1000
  def normalize_timeout({value, :milliseconds}), do: value
  def normalize_timeout({value, :seconds}), do: value * 1000
  def normalize_timeout({value, :minutes}), do: value * 60 * 1000
end
