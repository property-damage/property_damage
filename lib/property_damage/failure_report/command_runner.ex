defmodule PropertyDamage.FailureReport.CommandRunner do
  @moduledoc false
  # Runs a shell command with a text on its standard input, for
  # `mix pd.explain --with`.
  #
  # Erlang ports never close the standard input of their program and never kill
  # more than the one process they started, so this module uses POSIX tools
  # around the port instead:
  #
  #   * The text goes to a temp file (mode 0600, in a fresh directory of mode
  #     0700), and the command reads that file as its standard input, so it
  #     sees the end of the input after the last byte.
  #   * The command runs as `sh -c COMMAND`, started under `setsid -w`, so it
  #     leads its own process group. On a timeout the whole group gets SIGKILL
  #     with `kill -KILL -- -PID`, which also reaches children and
  #     grandchildren. `-w` makes `setsid` wait and pass the exit status on
  #     when it has to fork.
  #   * Where `setsid` does not exist (macOS), the command runs without its
  #     own group, and a timeout kills the descendants of the command's pid
  #     instead: each level is stopped first, so it cannot fork more, the
  #     children are read from `ps -A -o pid=,ppid=`, and the deepest process
  #     is killed first. `force_fallback: true` takes this path on any system.
  #
  # A helper process owns the port and the temp files and watches the caller.
  # When the caller dies, however it dies, the helper kills the command and
  # removes the files.

  @tmp_prefix "pd_explain_"

  @type result ::
          {:ok, binary()}
          | {:exit, non_neg_integer(), binary()}
          | {:timeout, binary()}
          | {:error, String.t()}

  @doc """
  Runs `command` with `input` on its standard input.

  Returns `{:ok, stdout}` when the command exits with 0, `{:exit, status,
  stdout}` for another status, `{:timeout, stdout}` when it runs longer than
  `timeout_ms` (the output up to the kill), and `{:error, reason}` when it
  cannot be started. Standard error of the command is not captured.
  """
  @spec run(String.t(), binary(), pos_integer(), keyword()) :: result()
  def run(command, input, timeout_ms, opts \\ []) do
    caller = self()
    ref = make_ref()

    {_pid, monitor} =
      spawn_monitor(fn -> work(caller, ref, command, input, timeout_ms, opts) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, "cannot run the command (#{inspect(reason)})"}
    end
  end

  # --- helper process --------------------------------------------------------

  defp work(caller, ref, command, input, timeout_ms, opts) do
    caller_monitor = Process.monitor(caller)

    case make_dir() do
      {:ok, dir} ->
        try do
          send(caller, {ref, supervise(caller_monitor, dir, command, input, timeout_ms, opts)})
        after
          File.rm_rf(dir)
        end

      {:error, reason} ->
        send(caller, {ref, {:error, "cannot run the command (#{:file.format_error(reason)})"}})
    end
  end

  defp make_dir do
    dir = Path.join(System.tmp_dir!(), "#{@tmp_prefix}#{System.pid()}_#{unique()}")

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    end
  end

  defp unique do
    "#{System.os_time(:microsecond)}_#{System.unique_integer([:positive])}"
  end

  defp supervise(caller_monitor, dir, command, input, timeout_ms, opts) do
    prompt = Path.join(dir, "prompt")
    pid_file = Path.join(dir, "pid")

    with :ok <- File.write(prompt, ""),
         :ok <- File.chmod(prompt, 0o600),
         :ok <- File.write(prompt, input) do
      port = open_port(command, prompt, pid_file, opts)
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      try do
        collect(port, caller_monitor, pid_file, deadline, opts, [])
      after
        close(port)
      end
    else
      {:error, reason} -> {:error, "cannot run the command (#{:file.format_error(reason)})"}
    end
  end

  # $1 is the command, $2 the pid file and $3 the input file. The shell records
  # its own pid, which is the group leader under setsid, and then becomes the
  # command's shell.
  @script ~S[echo $$ > "$2"; exec sh -c "$1" < "$3"]

  defp open_port(command, prompt, pid_file, opts) do
    inner = ["/bin/sh", "-c", @script, "sh", command, pid_file, prompt]

    {exe, args} =
      case setsid(opts) do
        nil -> {"/bin/sh", tl(inner)}
        setsid -> {setsid, ["-w" | inner]}
      end

    Port.open({:spawn_executable, exe}, [:binary, :exit_status, :hide, args: args])
  end

  defp setsid(opts) do
    if Keyword.get(opts, :force_fallback, false), do: nil, else: System.find_executable("setsid")
  end

  defp collect(port, caller_monitor, pid_file, deadline, opts, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, caller_monitor, pid_file, deadline, opts, [acc | data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:exit, status, IO.iodata_to_binary(acc)}

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        kill(port, pid_file, opts)
        exit(:normal)
    after
      remaining ->
        kill(port, pid_file, opts)
        {:timeout, IO.iodata_to_binary([acc, drain(port, [])])}
    end
  end

  # Output that arrived before the kill.
  defp drain(port, acc) do
    receive do
      {^port, {:data, data}} -> drain(port, [acc | data])
    after
      0 -> acc
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # --- killing ---------------------------------------------------------------

  defp kill(port, pid_file, opts) do
    case {read_pid(pid_file), setsid(opts)} do
      {nil, _} -> os_pid(port) && kill_tree(os_pid(port))
      {pid, nil} -> kill_tree(pid)
      {pid, _setsid} -> kill_group(port, pid)
    end
  end

  # `setsid -w` reports a child that a signal killed, so it is killed first to
  # keep that message off the terminal.
  defp kill_group(port, pid) do
    if os_pid(port), do: signal("KILL", os_pid(port))
    signal("KILL", "-#{pid}")
  end

  defp read_pid(pid_file) do
    with {:ok, text} <- File.read(pid_file),
         {pid, ""} when pid > 1 <- Integer.parse(String.trim(text)) do
      pid
    else
      _ -> nil
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp kill_tree(pid) do
    signal("STOP", pid)
    Enum.each(children(pid), &kill_tree/1)
    signal("KILL", pid)
  end

  defp children(pid) do
    {table, _status} = System.cmd("ps", ["-A", "-o", "pid=,ppid="])

    for line <- String.split(table, "\n", trim: true),
        [child, parent] <- [String.split(line)],
        parent == Integer.to_string(pid),
        do: String.to_integer(child)
  end

  # The shell's own `kill` accepts a negative pid for a group.
  defp signal(name, target) do
    System.cmd("sh", ["-c", ~S[kill -"$1" -- "$2" 2>/dev/null], "sh", name, to_string(target)])
  end
end
