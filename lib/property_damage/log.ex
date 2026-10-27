defmodule PropertyDamage.Log do
  @moduledoc """
  Log lines for the failure report (DR-054).

  An adapter, a nemesis or a mock handler calls `PropertyDamage.log/2` to say
  what it did: the request it sent, the response it read, the rows it seeded.
  A line is shown only in a failure report, under the step that wrote it,
  beside that step's events. PropertyDamage never prints a line during a run
  and never forwards one to Elixir's `Logger`.

      require PropertyDamage

      def execute(%Transfer{amount: amount}, _user_context, _runtime) do
        PropertyDamage.log("POST /transfers", tags: [:http, :url])
        PropertyDamage.log(%{amount: amount}, tags: [:http, :body])
        {:ok, [%Transferred{amount: amount}]}
      end

  ## Scopes

  Every call needs a scope. The engine opens one before it runs user code at
  an execution point: an adapter's `setup/1`, each setup command, each root
  and each leaf, each settle or stutter attempt, a nemesis's `inject/2` and
  `restore/2`, mock setup, each teardown command and an adapter's
  `teardown/1`. The scope is held by the process that runs the code (the
  per-command `Task` for `execute/3`) and removed when that code returns.

  `PropertyDamage.log/2` looks for a scope in the calling process, then in
  each process of its `$callers` list, so a `Task` the adapter starts logs to
  the step that started it. The walk ends at the first process that is no
  longer alive: a process left running by a step that has ended finds no
  scope, and its line never lands under a later step. A call that finds no
  scope raises `PropertyDamage.Log.NoScopeError`.

  Some points run in a process that outlives them: an adapter's `setup/1`
  and `teardown/1`, injector and mock setup and teardown, and a nemesis's
  `inject/2` and `restore/2`. Such a point records the processes alive when
  it opens, and admits a `$callers` chain only when the process directly
  below its holder in that chain started while the point ran. A `Task` that
  `setup/1` starts and awaits logs under `setup/1`; a process that `setup/1`
  leaves running finds no scope during `teardown/1`.

  A process that is neither the executing one nor started through `Task`
  (a `GenServer`, for example) logs through the runtime it was handed, with
  `PropertyDamage.Runtime.log/3`. Both forms write to the same place.

  ## Storage

  A line goes, at the call and synchronously, into the command's
  `PropertyDamage.Runtime.Sink`, which the engine owns; a timeout that kills
  the `Task` running `execute/3` loses no line written before it. When the
  command ends, the engine moves its lines into the run's
  `PropertyDamage.RunTrace` (`logs`, keyed by the step's
  `PropertyDamage.Sequence.Position`). A line written after its command ended
  is dropped.

  Lines live only in memory: a saved trace or report, a replay artifact and
  every other file carry none.
  """

  alias PropertyDamage.Log.{Line, NoScopeError}
  alias PropertyDamage.Runtime.Sink

  @scope_key {__MODULE__, :scope}

  @typedoc """
  Where a step's lines are kept: a `PropertyDamage.Sequence.Position` for a
  command, `:adapter_setup` for an adapter's `setup/1` (and the injector and
  mock setup around it), `:adapter_teardown` for its `teardown/1` (and the
  mock and injector teardown around it).
  """
  @type key :: PropertyDamage.Sequence.Position.t() | :adapter_setup | :adapter_teardown

  @typedoc "Lines by the step they belong to, each list in the order written."
  @type logs :: %{key() => [Line.t()]}

  @typedoc "A function that writes one line: `(message, opts) -> :ok`."
  @type writer :: (term(), keyword() -> :ok)

  # ==========================================================================
  # The call
  # ==========================================================================

  @doc false
  # The body of `PropertyDamage.log/2`: finds the scope and writes the line.
  @spec __log__(term(), [atom()], {String.t() | nil, non_neg_integer() | nil}) :: :ok
  def __log__(message, tags, {file, line} = location) do
    case lookup() do
      nil -> raise NoScopeError, file: file, line: line, pid: self()
      writer -> writer.(message, tags: tags, location: location)
    end

    :ok
  end

  @doc false
  # Validates the options of a `PropertyDamage.log/2` call at expansion and
  # returns its tags. `opts` must be a literal keyword list whose one key is
  # `tags:`, holding a literal list of atoms.
  @spec __tags__!(Macro.t(), Macro.Env.t()) :: [atom()]
  def __tags__!(opts, caller) do
    cond do
      not Keyword.keyword?(opts) ->
        compile_error!(
          caller,
          "the options of PropertyDamage.log/2 must be a literal keyword list, got: " <>
            Macro.to_string(opts)
        )

      (unknown = Keyword.keys(opts) -- [:tags]) != [] ->
        compile_error!(
          caller,
          "unknown option #{Enum.map_join(unknown, ", ", &"#{&1}:")} for PropertyDamage.log/2"
        )

      true ->
        tags = Keyword.get(opts, :tags, [])

        if is_list(tags) and Enum.all?(tags, &is_atom/1) do
          tags
        else
          compile_error!(
            caller,
            "the tags of PropertyDamage.log/2 must be a literal list of atoms, got: tags: " <>
              Macro.to_string(tags)
          )
        end
    end
  end

  defp compile_error!(caller, problem) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: problem <> ". tags: is the only option, a literal list of atoms"
  end

  @doc false
  # Validates the options of a `Runtime.log/3` call and returns its tags.
  @spec tags!(term()) :: [atom()]
  def tags!(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:tags],
         tags when is_list(tags) <- Keyword.get(opts, :tags, []),
         true <- Enum.all?(tags, &is_atom/1) do
      tags
    else
      _invalid ->
        raise ArgumentError,
              "invalid options for PropertyDamage.Runtime.log/3: #{inspect(opts)}. " <>
                "tags: is the only option, a list of atoms"
    end
  end

  # ==========================================================================
  # Scopes (framework side)
  # ==========================================================================

  @doc false
  # The function that writes one line of attempt `attempt` into `sink`. A
  # line written after the sink stopped (its command ended) is dropped.
  @spec writer(pid(), pos_integer()) :: writer()
  def writer(sink, attempt) do
    fn message, opts ->
      {file, line} = Keyword.get(opts, :location, {nil, nil})

      entry = %Line{
        message: message,
        tags: Keyword.get(opts, :tags, []),
        file: file,
        line: line,
        timestamp: System.monotonic_time(:millisecond),
        attempt: attempt
      }

      try do
        Sink.add_line(sink, entry)
      catch
        :exit, _sink_stopped -> :ok
      end

      :ok
    end
  end

  # A scope, as a process holds it in its dictionary: a writer alone when the
  # process lives only as long as the scope (the per-command Task), or the
  # writer with the processes alive when the scope opened when the process
  # outlives it (an inline execution point).
  @typep scope :: writer() | {writer(), [pid()]}

  @doc false
  # The scope the calling process finds: its own, else the first process of
  # its `$callers` that holds one. A dead process ends the walk, and so does
  # an inline scope the chain does not belong to (`admit/2`).
  @spec lookup() :: writer() | nil
  def lookup do
    case Process.get(@scope_key) do
      nil -> lookup_callers(self(), Process.get(:"$callers", []))
      scope -> writer_of(scope)
    end
  end

  # `below` is the process the walk came from: the caller `pid` started it,
  # or started the process that started it.
  defp lookup_callers(below, [pid | rest]) when is_pid(pid) and node(pid) == node() do
    case scope_in(pid) do
      :dead -> nil
      nil -> lookup_callers(pid, rest)
      scope -> admit(scope, below)
    end
  end

  defp lookup_callers(_below, _callers), do: nil

  # A process outlives an inline scope's code, so a process it started for
  # one execution point can still run during a later one. The inline scope
  # admits the chain only when the process directly below its holder was
  # started after the scope opened, by the code of this point.
  defp admit({writer, alive_at_open}, below),
    do: if(:lists.member(below, alive_at_open), do: nil, else: writer)

  defp admit(writer, _below), do: writer

  defp writer_of({writer, _alive_at_open}), do: writer
  defp writer_of(writer), do: writer

  @doc false
  # The scope `pid` holds: nil when it holds none, `:dead` when it has
  # exited. `:key` reads the one dictionary key, which needs OTP 26.2 or
  # later, and falls back to `:dictionary`, which reads the whole dictionary.
  @spec scope_in(pid(), :key | :dictionary) :: scope() | nil | :dead
  def scope_in(pid, read \\ :key)

  def scope_in(pid, :key) do
    case :erlang.process_info(pid, {:dictionary, @scope_key}) do
      :undefined -> :dead
      {{:dictionary, @scope_key}, :undefined} -> nil
      {{:dictionary, @scope_key}, scope} -> scope
    end
  rescue
    ArgumentError -> scope_in(pid, :dictionary)
  end

  def scope_in(pid, :dictionary) do
    case Process.info(pid, :dictionary) do
      nil -> :dead
      {:dictionary, dictionary} -> dictionary |> List.keyfind(@scope_key, 0) |> scope_entry()
    end
  end

  defp scope_entry({@scope_key, scope}), do: scope
  defp scope_entry(nil), do: nil

  @doc false
  # Makes `writer` the calling process's scope for the rest of its life (the
  # per-command Task). A nil writer opens nothing.
  @spec enter(writer() | nil) :: :ok
  def enter(nil), do: :ok

  def enter(writer) when is_function(writer, 2) do
    Process.put(@scope_key, writer)
    :ok
  end

  @doc false
  # Runs `fun` with `writer` as the calling process's scope, then restores
  # the scope it had before. The scope records the processes alive when it
  # opens: a process among them is not one this code started, and finds no
  # scope here (`admit/2`).
  @spec with_scope(writer() | nil, (-> result)) :: result when result: var
  def with_scope(nil, fun), do: fun.()

  def with_scope(writer, fun) do
    previous = Process.put(@scope_key, {writer, Process.list()})

    try do
      fun.()
    after
      if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
    end
  end

  @doc false
  # Runs `fun` with a sink of its own, given to it, and returns its result
  # with the lines written into the sink, in order. The sink stops even when
  # `fun` raises.
  @spec collect((pid() -> result)) :: {result, [Line.t()]} when result: var
  def collect(fun) do
    {:ok, sink} = Sink.start_link()

    try do
      result = fun.(sink)
      {result, Sink.lines(sink)}
    after
      Sink.stop(sink)
    end
  end

  @doc false
  # Runs `fun` in the calling process as an execution point of its own
  # (an adapter's setup/1 or teardown/1, a nemesis call) and returns its
  # result with the lines it wrote.
  @spec inline((-> result)) :: {result, [Line.t()]} when result: var
  def inline(fun), do: collect(fn sink -> with_scope(writer(sink, 1), fun) end)

  @doc false
  # Adds `lines` to the end of the lines kept under `key`. No lines, no key.
  @spec append(logs(), key(), [Line.t()]) :: logs()
  def append(logs, _key, []), do: logs
  def append(logs, key, lines), do: Map.update(logs, key, lines, &(&1 ++ lines))

  @doc false
  # Every line of `right` that `left` does not already hold, added to it:
  # merges the logs of states forked from one state.
  @spec merge(logs(), logs()) :: logs()
  def merge(left, right) do
    Map.merge(left, right, fn _key, kept, other -> kept ++ (other -- kept) end)
  end
end
