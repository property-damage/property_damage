# Parent-side driver for a per-document Elixir evaluation worker.
#
# Owns the worker OS process (a Port), sends fences to evaluate, and reads back
# pass/fail replies. Incoming data is scanned line by line for a protocol reply
# (OK/ERR + valid base64); any incidental noise lines (e.g. app-start chatter)
# are discarded, so the channel is robust.
defmodule DocsVerify.ElixirSession do
  @worker_path Path.join(__DIR__, "eval_worker.exs")

  defstruct [:port, :buffer]

  def start(ebin_paths, cwd, env) do
    elixir = System.find_executable("elixir") || "elixir"

    port =
      Port.open(
        {:spawn_executable, elixir},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, [@worker_path | ebin_paths]},
          {:cd, cwd},
          {:env, charlist_env(env)}
        ]
      )

    %__MODULE__{port: port, buffer: ""}
  end

  @doc """
  Evaluate a chunk of Elixir source in the worker's accumulating context.
  Returns `{:ok, session}`, `{:error, message, session}`, or
  `{:timeout, session}`.
  """
  def eval(session, code, timeout) do
    Port.command(session.port, "EVAL " <> Base.encode64(code) <> "\n")
    recv_reply(session, timeout)
  end

  def stop(session) do
    try do
      Port.command(session.port, "QUIT\n")
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

  defp recv_reply(session, timeout) do
    case take_reply(session.buffer) do
      {:reply, {:ok, _out}, rest} ->
        {:ok, %{session | buffer: rest}}

      {:reply, {:error, message}, rest} ->
        {:error, message, %{session | buffer: rest}}

      {:more, buffer} ->
        session = %{session | buffer: buffer}

        receive do
          {port, {:data, data}} when port == session.port ->
            recv_reply(%{session | buffer: session.buffer <> data}, timeout)

          {port, {:exit_status, status}} when port == session.port ->
            {:error, "elixir worker exited unexpectedly (status #{status})", session}
        after
          timeout ->
            {:timeout, session}
        end
    end
  end

  # Scan complete lines for the first protocol reply; drop preceding noise lines;
  # keep the trailing partial line buffered.
  defp take_reply(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [partial]} = Enum.split(parts, length(parts) - 1)
    scan(complete, partial)
  end

  defp scan([], partial), do: {:more, partial}

  defp scan([line | rest], partial) do
    case parse_reply(line) do
      {:reply, reply} -> {:reply, reply, Enum.join(rest ++ [partial], "\n")}
      :skip -> scan(rest, partial)
    end
  end

  defp parse_reply(line) do
    cond do
      String.starts_with?(line, "OK ") ->
        decode(binary_part(line, 3, byte_size(line) - 3), :ok)

      line == "OK" ->
        {:reply, {:ok, ""}}

      String.starts_with?(line, "ERR ") ->
        decode(binary_part(line, 4, byte_size(line) - 4), :error)

      true ->
        :skip
    end
  end

  defp decode(payload, tag) do
    case Base.decode64(payload) do
      {:ok, text} -> {:reply, {tag, text}}
      :error -> :skip
    end
  end

  defp charlist_env(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end
end
