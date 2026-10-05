defmodule PropertyDamage.Executor.Settle do
  @moduledoc false
  # Settle execution for the executor (DR-029).
  #
  # Wraps a command's `adapter.execute/3` in the retry/backoff loop for `:probe`
  # and `:async` execution semantics, sourcing the semantics and timing from the
  # resolved command spec (falling back to the command's own declarations). The
  # pure settle policy (the retry loop, semantics/config resolution) lives in
  # PropertyDamage.Settle; this module is the executor-side glue. It is a leaf
  # module: it depends only on the Settle policy and the adapter, not back on
  # Executor.
  #
  # The framework push-settle await for command-correlated injector events
  # (Command.awaits/2, DR-030) will also live here.

  alias PropertyDamage.Executor.Timeout
  alias PropertyDamage.Settle

  # Execute command with settle logic for probes/async, sourced from the spec.
  # Each adapter.execute/3 attempt is bounded by adapter.timeout/1 (DR-032).
  #
  # A raising execute/3 comes back as `{:raised, exception, stacktrace}`, tagged
  # where the raise was caught (Timeout.execute_tagged/4). The settle loop only
  # speaks the adapter protocol, so on the probe/async path the tag is thrown
  # past it and caught here; a raise ends the settle loop, as an `{:error, _}`
  # attempt does.
  def execute_with_settle(command, adapter, user_context, runtime, spec) do
    execution = settle_execution(command, spec)

    if execution in [:probe, :async] do
      config = settle_config(command, spec)

      attempt = fn ->
        case Timeout.execute_tagged(adapter, command, user_context, runtime) do
          {:raised, _exception, _stacktrace} = raised -> throw({__MODULE__, raised})
          result -> result
        end
      end

      try do
        Settle.settle(attempt,
          timeout_ms: config.timeout_ms,
          interval_ms: config.interval_ms,
          backoff: config.backoff
        )
      catch
        :throw, {__MODULE__, raised} -> raised
      end
    else
      Timeout.execute_tagged(adapter, command, user_context, runtime)
    end
  end

  defp settle_execution(command, nil), do: Settle.get_semantics(command)
  defp settle_execution(_command, spec), do: Map.get(spec, :execution, :sync)

  defp settle_config(command, nil), do: Settle.get_config(command)
  defp settle_config(_command, %{settle: settle}) when is_map(settle), do: settle
  defp settle_config(command, _spec), do: Settle.get_config(command)
end
