defmodule PropertyDamage.Next.Test.OwnLog do
  @moduledoc false
  # Captures the log lines of one call, and only those. ExUnit's
  # `with_log/2` hands every log event of every process to every capture
  # open at the time, so a test in an async module would also read what
  # other tests log while it runs.
  #
  # One `:logger` handler serves all calls. It is installed on first use and
  # never removed, because `Logger.flush/0` (run by `with_log/2` in any
  # test) lists the handlers and then reads each one's config, so a handler
  # that disappears in between crashes that flush. Each call registers its
  # owner pid and a StringIO sink in an ETS table; the handler writes an
  # event to a sink only when the logging process is the owner or names the
  # owner among its callers or ancestors. The `:formatter` option of
  # `with_log/2` could do the filtering, but Elixir 1.17 ignores that
  # option, so this module does not depend on it. The outer `with_log/2`
  # only mutes the console handler while the call runs.
  #
  # The table lives in a helper process that is never stopped, so it
  # outlives the test process that created it.

  import ExUnit.CaptureLog, only: [with_log: 1]

  @table __MODULE__
  @handler_id __MODULE__

  @doc "Runs `fun` and returns `{result, log}`, the log holding only this caller's lines."
  def with_own_log(fun) do
    ensure_installed()
    {:ok, sink} = StringIO.open("")
    key = make_ref()
    true = :ets.insert(@table, {key, self(), sink})

    {result, _everything} =
      with_log(fn ->
        try do
          fun.()
        after
          :ets.delete(@table, key)
        end
      end)

    {_input, log} = StringIO.contents(sink)
    StringIO.close(sink)
    {result, log}
  end

  @doc false
  # The `:logger` handler callback, run in the process that logged. It must
  # not raise: a handler that fails is removed by `:logger`.
  def log(%{meta: meta} = event, %{config: %{formatter: {module, formatter_config}}}) do
    pid = Map.get(meta, :pid)

    for {_key, owner, sink} <- :ets.tab2list(@table), owned?(pid, owner) do
      try do
        IO.write(sink, module.format(event, formatter_config))
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  rescue
    _error -> :ok
  end

  # Creates the table and installs the handler once per VM. Concurrent first
  # calls race on both steps, so each step tolerates "already there".
  defp ensure_installed do
    if :ets.whereis(@table) == :undefined, do: start_table_owner()

    case :logger.add_handler(@handler_id, __MODULE__, %{
           config: %{formatter: Logger.default_formatter([])}
         }) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
    end
  end

  defp start_table_owner do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      try do
        :ets.new(@table, [:named_table, :public, :set])
      rescue
        ArgumentError -> :lost_race
      end

      send(parent, {ref, :ready})
      Process.sleep(:infinity)
    end)

    receive do
      {^ref, :ready} -> :ok
    end
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
