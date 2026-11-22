defmodule PropertyDamage.Next.Test.OwnLog do
  @moduledoc false
  # Captures the log lines of one call, and only those. ExUnit's
  # `with_log/2` hands every log event of every process to every capture
  # open at the time, so a test in an async module would also read what
  # other tests log while it runs. The formatter below keeps an event only
  # when the calling process logged it, or a process that names the caller
  # among its callers or ancestors; it formats every other event as nothing.

  import ExUnit.CaptureLog, only: [with_log: 2]

  @doc "Runs `fun` and returns `{result, log}`, the log holding only this caller's lines."
  def with_own_log(fun) do
    formatter = Logger.default_formatter([])
    with_log([formatter: {__MODULE__, %{owner: self(), formatter: formatter}}], fun)
  end

  @doc false
  # The formatter callback `with_log/2` calls for each event.
  def format(%{meta: meta} = event, %{owner: owner, formatter: {module, config}}) do
    if owned?(Map.get(meta, :pid), owner), do: module.format(event, config), else: ""
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
