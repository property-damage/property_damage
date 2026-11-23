defmodule PropertyDamage.Next.Runtime do
  @moduledoc """
  PD's handle for the ports, passed to the adapter's `setup/2`.

  The adapter keeps it and uses PD's services through it; its contents are
  PD's own and may change, so the adapter never reads its fields.
  """

  alias PropertyDamage.Next.{
    AcknowledgedIgnoredAssignError,
    AcknowledgedUnsetAssignError,
    AssignCounts
  }

  defstruct []

  @opaque t :: %__MODULE__{}

  @scope_key {__MODULE__, :running_step}

  @doc """
  Acknowledges that the adapter acted on the assign `key` of the step it is
  executing, and returns `:ok`.

  A layer sets an assign beside a command for a port to act on, and an
  adapter calls this wherever it takes an assign into account; PD counts
  the calls per command and key. `runtime` is the handle `setup/2` received.

  PD finds the running step from the process that called `execute/3`, or
  from a process that lists it in `$callers`, as a `Task` started there
  does. The call raises:

    * `ArgumentError` outside a step
    * `PropertyDamage.Next.AcknowledgedUnsetAssignError` when the step did
      not set `key`: the key is absent, `nil` or `false`
    * `PropertyDamage.Next.AcknowledgedIgnoredAssignError` when the target
      lists `key` in `ignored_assigns:`
  """
  @spec ack(t(), atom()) :: :ok
  def ack(%__MODULE__{}, key) when is_atom(key), do: do_ack(key)

  defp do_ack(key) do
    case find_scope() do
      nil ->
        raise ArgumentError,
              "Runtime.ack/2 was called outside a step: acknowledge an assign " <>
                "from the adapter's execute/3, or from a process it started with a Task"

      %{ignored: ignored, target: target} = scope ->
        cond do
          key in ignored ->
            raise AcknowledgedIgnoredAssignError, key: key, target: target

          key not in scope.set ->
            raise AcknowledgedUnsetAssignError, key: key, assigns: scope.set

          true ->
            if scope.counts,
              do: AssignCounts.record_acknowledged(scope.counts, target, scope.command, key)

            :ok
        end
    end
  end

  @doc false
  # Makes `scope` the running step of the calling process for the length of
  # `fun`. A scope is `%{target:, command:, set:, ignored:, counts:}`.
  def with_step(scope, fun) do
    Process.put(@scope_key, scope)

    try do
      fun.()
    after
      Process.delete(@scope_key)
    end
  end

  defp find_scope do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn
      pid when pid == self() -> Process.get(@scope_key)
      pid when is_pid(pid) and node(pid) == node() -> scope_of(pid)
      _ -> nil
    end)
  end

  defp scope_of(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @scope_key, 0) do
          {_, scope} -> scope
          nil -> nil
        end

      nil ->
        nil
    end
  end
end
