defmodule PropertyDamage.Next.Test.OwnLog do
  @moduledoc false
  # Captures the log lines of one call, and only those. ExUnit's
  # `with_log/2` hands every log event of every process to every capture
  # open at the time, so a test in an async module would also read what
  # other tests log while it runs. This module adds a logger handler of its
  # own for the duration of the call; the handler keeps an event only when
  # the calling process logged it, or a process that names the caller among
  # its callers or ancestors. The `:formatter` option of `with_log/2` could
  # do the filtering, but Elixir 1.17 ignores that option, so the handler
  # does not depend on it. The outer `with_log/2` only mutes the console
  # handler while the call runs.

  import ExUnit.CaptureLog, only: [with_log: 1]

  @doc "Runs `fun` and returns `{result, log}`, the log holding only this caller's lines."
  def with_own_log(fun) do
    {:ok, sink} = StringIO.open("")
    id = :"#{inspect(__MODULE__)}.#{System.unique_integer([:positive])}"
    config = %{owner: self(), formatter: Logger.default_formatter([]), sink: sink}

    {result, _everything} =
      with_log(fn ->
        :ok = :logger.add_handler(id, __MODULE__, %{config: config})

        try do
          fun.()
        after
          :logger.remove_handler(id)
        end
      end)

    {_input, log} = StringIO.contents(sink)
    StringIO.close(sink)
    {result, log}
  end

  @doc false
  # The `:logger` handler callback, run in the process that logged.
  def log(%{meta: meta} = event, %{config: config}) do
    %{owner: owner, formatter: {module, formatter_config}, sink: sink} = config

    if owned?(Map.get(meta, :pid), owner) do
      IO.write(sink, module.format(event, formatter_config))
    end

    :ok
  end

  defp owned?(owner, owner), do: true

  defp owned?(pid, owner) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        owner in (lineage(dictionary, :"$callers") ++ lineage(dictionary, :"$ancestors"))

      nil ->
        false
    end
  end

  defp owned?(_pid, _owner), do: false

  # A process dictionary also holds keys that are not atoms, so this reads
  # it as a plain list of pairs.
  defp lineage(dictionary, key) do
    case List.keyfind(dictionary, key, 0) do
      {^key, processes} -> processes
      nil -> []
    end
  end
end
