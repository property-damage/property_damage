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
  `restore/2`, mock setup, a mock's `on_command/2` and `on_event/2`, each
  teardown command and an adapter's `teardown/1`. A mock's `on_command/2`
  and `on_event/2` run under a scope of the command they are told of, so
  their lines print under that command's step. The scope is held by the
  process that runs the code (the per-command `Task` for `execute/3`, the
  mock registry for a mock's callbacks) and removed when that code returns.

  `PropertyDamage.log/2` looks for a scope in the calling process, then in
  each process of its `$callers` list, so a `Task` the adapter starts logs to
  the step that started it. The walk ends at the first process that is no
  longer alive: a process left running by a step that has ended finds no
  scope, and its line never lands under a later step. A call that finds no
  scope raises `PropertyDamage.Log.NoScopeError`.

  Some points run in a process that outlives them: an adapter's `setup/1`
  and `teardown/1`, injector and mock setup and teardown, a nemesis's
  `inject/2` and `restore/2`, and a mock's `on_command/2` and `on_event/2`.
  Such a point admits a `$callers` chain only when the process directly
  below its holder in that chain was started by the holder while the point
  ran: the point marks its holder's `$callers` with a token of its own while
  it runs, and a process started then carries the token. A `Task` that
  `setup/1` starts and awaits logs under `setup/1`; a process that `setup/1`
  leaves running finds no scope during `teardown/1`.

  A process that is neither the executing one nor started through `Task`
  (a `GenServer`, for example) logs through the runtime it was handed, with
  `PropertyDamage.Runtime.log/3`. Both forms write to the same place.

  Code outside a run, such as seeding a system before the run starts, gets a
  scope from `capture/1`, and its lines reach the report through the run's
  `setup_log:` option.

  ## Redaction and tag filters

  The caller redacts. A line holds its message as given, and the failure
  report prints it as given, so a secret in a message reaches the report. A
  tag filter (`log: [only: tags, except: tags]` on `PropertyDamage.run/1`,
  `PropertyDamage.ExUnit.format_failure/2`, or the environment variable
  `PD_LOG`; see `PropertyDamage.Log.Filter`) hides whole lines from one reader
  of one printed report. It does not protect a secret: the hidden line is
  still in the report in memory, and a filter changes nothing a run keeps.
  Keep a secret out of the message, in the code that logs.

  ## Storage

  A line goes, at the call and synchronously, into the command's
  `PropertyDamage.Runtime.Sink`, which the engine owns; a timeout that kills
  the `Task` running `execute/3` loses no line written before it. When the
  command ends, the engine moves its lines into the run's
  `PropertyDamage.RunTrace` (`logs`, keyed by the step's
  `PropertyDamage.Sequence.Position`). A line written after its command ended
  is dropped.

  A settle or stutter retry can run one command hundreds of times, so the sink
  caps what a step keeps (DR-054 decision 13): the lines of the first attempt
  and of the last three attempts. When a newer attempt pushes an older one out
  of the last three, the sink drops that attempt's lines at once and counts
  them, so a 1,000-attempt settle holds the lines of at most four attempts. One
  `PropertyDamage.Log.Gap` stands in the step's lines, between the first
  attempt's and the kept ones, with the number of attempts and lines dropped;
  the failure report prints it as `... 296 attempts omitted (1,184 lines)`. The
  cap drops whole attempts and never cuts a line or a value. The stutter
  retries of a command count as further attempts of the same step, after its
  settle attempts. `log: [keep_attempts: n]` on `PropertyDamage.run/1`,
  `PropertyDamage.shrink_further/2` or `PropertyDamage.Replay.start/2` changes
  the number of last attempts kept. Lines of `capture/1`, of an adapter's
  `setup/1` and `teardown/1` and of the other points that have no attempts are
  never capped.

  Lines live only in memory: a saved trace or report, a replay artifact and
  every other file carry none.
  """

  alias PropertyDamage.Log.{Gap, Line, NoScopeError}
  alias PropertyDamage.Runtime.Sink

  @scope_key {__MODULE__, :scope}

  @typedoc """
  Where a step's lines are kept: a `PropertyDamage.Sequence.Position` for a
  command, `:adapter_setup` for an adapter's `setup/1` (and the injector and
  mock setup around it), `:adapter_teardown` for its `teardown/1` (and the
  mock and injector teardown around it).
  """
  @type key :: PropertyDamage.Sequence.Position.t() | :adapter_setup | :adapter_teardown

  @typedoc """
  Lines by the step they belong to, each list in the order written, with a
  `PropertyDamage.Log.Gap` in the place of the attempts the retry cap dropped.
  """
  @type logs :: %{key() => [Line.t() | Gap.t()]}

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
  # writer with the scope's token when the process outlives it (an inline
  # execution point; see `with_scope/2`).
  @typep scope :: writer() | {writer(), pid()}

  @doc false
  # The scope the calling process finds: its own, else the first process of
  # its `$callers` that holds one. A dead process ends the walk, and so does
  # an inline scope the chain does not belong to (`admit/2`).
  @spec lookup() :: writer() | nil
  def lookup do
    case Process.get(@scope_key) do
      nil -> lookup_callers(Process.get(:"$callers", []))
      scope -> writer_of(scope)
    end
  end

  defp lookup_callers([pid | rest]) when is_pid(pid) and node(pid) == node() do
    case scope_in(pid) do
      :dead -> nil
      nil -> lookup_callers(rest)
      scope -> admit(scope, rest)
    end
  end

  defp lookup_callers(_callers), do: nil

  # A process outlives an inline scope's code, so a process it started for
  # one execution point can still run during a later one. While an inline
  # scope is open, its holder's `$callers` starts with the scope's token, so
  # a process the holder starts during the point carries the token right
  # after the holder in its own `$callers`, and a process started before the
  # point opened does not. The scope admits only a chain that carries it.
  defp admit({writer, token}, [token | _rest]), do: writer
  defp admit({_writer, _token}, _rest), do: nil
  defp admit(writer, _rest), do: writer

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
  # the scope and the `$callers` it had before. The scope gets a token of its
  # own, a pid no other scope holds, put first in the calling process's
  # `$callers` while `fun` runs, so the processes `fun` starts carry it
  # (`admit/2`). The token only has to be unique, so it is a process that
  # exits at once; a dead pid in `$callers` ends a lookup that reaches it.
  @spec with_scope(writer() | nil, (-> result)) :: result when result: var
  def with_scope(nil, fun), do: fun.()

  def with_scope(writer, fun) do
    token = spawn(fn -> :ok end)
    previous = Process.put(@scope_key, {writer, token})
    callers = Process.get(:"$callers")
    Process.put(:"$callers", [token | callers || []])

    try do
      fun.()
    after
      if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
      if callers, do: Process.put(:"$callers", callers), else: Process.delete(:"$callers")
    end
  end

  @doc false
  # Runs `fun` with a sink of its own, given to it, and returns its result
  # with the lines the sink keeps, in order (`Sink.lines/1`). `opts` are the
  # sink's (`Sink.start_link/1`). The sink stops even when `fun` raises.
  @spec collect((pid() -> result), keyword()) :: {result, [Line.t() | Gap.t()]} when result: var
  def collect(fun, opts \\ []) do
    {:ok, sink} = Sink.start_link(opts)

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

  @doc """
  Runs `fun` as a scope and returns `{result, lines}`: what `fun` returned and
  the `PropertyDamage.Log.Line` structs it logged, in the order written.

  Use it for code that runs outside a run, such as seeding a system in an
  ExUnit `setup_all`, and hand the lines to the run as `setup_log: lines`
  (DR-054 decision 8):

      require PropertyDamage

      {accounts, setup_log} =
        PropertyDamage.Log.capture(fn ->
          PropertyDamage.log("seeding accounts", tags: [:seed])
          MyApp.seed!(alice: 100, bob: 0)
        end)

      PropertyDamage.run(model: MyModel, targets: targets(accounts), setup_log: setup_log)

  The same rules as for a run's scopes apply: `PropertyDamage.log/2` finds the
  capture in the calling process or in a process of its `$callers`, so a `Task`
  started inside `fun` logs into it. A nested `capture/1` collects into the
  innermost one, and the outer one gets none of its lines. A `capture/1`
  inside an adapter's `execute/3` keeps its lines out of the step. Lines have
  attempt 1. The capture closes when `fun` returns: a process left running
  finds no scope afterwards.

  An error, throw or exit in `fun` propagates, and the lines written before it
  are dropped. `fun` must be a 0-arity function, or `capture/1` raises
  `ArgumentError`.
  """
  @spec capture((-> result)) :: {result, [Line.t()]} when result: var
  def capture(fun) when is_function(fun, 0), do: inline(fun)

  def capture(other) do
    raise ArgumentError,
          "PropertyDamage.Log.capture/1 takes a 0-arity function, got: #{inspect(other)}"
  end

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
