# Persistent shell session for a single document.
#
# One bash process for the whole document, driven over a Port. cwd changes (`cd`)
# and env exports persist across fences because it is the SAME shell. Each fence
# is followed by a sentinel that reports the fence's exit status; a non-zero exit
# fails the document.
defmodule DocsVerify.ShellSession do
  @done ~r/__PD_SH_DONE__(-?\d+)__PD_SH_END__/

  defstruct [:port, :buffer]

  def start(cwd, env) do
    bash = System.find_executable("bash") || "/bin/bash"

    port =
      Port.open(
        {:spawn_executable, bash},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, ["-s"]},
          {:cd, cwd},
          {:env, charlist_env(env)}
        ]
      )

    %__MODULE__{port: port, buffer: ""}
  end

  @doc """
  Run a shell script fence. Returns `{:ok, output, session}` on exit 0,
  `{:error, exit_code, output, session}` on non-zero exit, or
  `{:timeout, session}`.
  """
  def run(session, script, timeout) do
    sentinel = ~s|printf '\\n__PD_SH_DONE__%d__PD_SH_END__\\n' "$?"\n|
    Port.command(session.port, script <> "\n" <> sentinel)
    read_until(session, session.buffer, timeout)
  end

  def stop(session) do
    try do
      Port.command(session.port, "exit\n")
    catch
      _, _ -> :ok
    end

    try do
      Port.close(session.port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp read_until(session, buffer, timeout) do
    case Regex.run(@done, buffer, return: :index) do
      [{full_s, full_l}, {grp_s, grp_l}] ->
        output = binary_part(buffer, 0, full_s)
        code_str = binary_part(buffer, grp_s, grp_l)
        rest_start = full_s + full_l
        rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)
        code = String.to_integer(code_str)
        session = %{session | buffer: rest}
        output = String.trim_trailing(output, "\n")

        if code == 0 do
          {:ok, output, session}
        else
          {:error, code, output, session}
        end

      nil ->
        receive do
          {port, {:data, data}} when port == session.port ->
            read_until(session, buffer <> data, timeout)

          {port, {:exit_status, status}} when port == session.port ->
            {:error, status, buffer <> "\n(shell session ended unexpectedly)",
             %{session | buffer: ""}}
        after
          timeout ->
            {:timeout, session}
        end
    end
  end

  defp charlist_env(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end
end
