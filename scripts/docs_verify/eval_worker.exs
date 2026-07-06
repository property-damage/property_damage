# Per-document Elixir evaluation worker (separate OS process).
#
# Launched by DocsVerify.ElixirSession as:
#     elixir eval_worker.exs <ebin_dir> <ebin_dir> ...
# with its cwd set to the document's isolated working directory.
#
# It holds ONE accumulating Elixir context for the whole document: bindings are
# threaded across evaluations, and modules defined by an earlier fence stay
# defined (they live in this VM's global module table) for later fences. A fresh
# worker per document keeps documents from seeing each other's modules.
#
# Wire protocol over stdio (line-framed, base64 payloads so multi-line code and
# captured output never break framing):
#     parent -> worker:  "EVAL <base64-code>\n"   |  "QUIT\n"
#     worker -> parent:  "OK <base64-output>\n"    |  "ERR <base64-message>\n"
# Fence stdout/stderr is captured (group-leader redirect to a StringIO) so it
# cannot corrupt the protocol channel; protocol I/O always targets the real
# group leader captured at startup.

real_gl = Process.group_leader()

System.argv()
|> Enum.each(fn ebin -> Code.append_path(String.to_charlist(ebin)) end)

# Best-effort: make PropertyDamage and its deps available. Silence the logger so
# framework log lines never interleave onto the protocol channel.
_ = Application.ensure_all_started(:property_damage)

try do
  Logger.configure(level: :emergency)
rescue
  _ -> :ok
end

defmodule DocsVerify.EvalWorker do
  def loop(gl, binding) do
    case IO.read(gl, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data ->
        line = String.trim_trailing(data, "\n")

        cond do
          line == "QUIT" ->
            :ok

          String.starts_with?(line, "EVAL ") ->
            code =
              line
              |> binary_part(5, byte_size(line) - 5)
              |> Base.decode64!()

            {result, output} = eval_capture(code, binding, gl)

            case result do
              {:ok, new_binding} ->
                IO.write(gl, "OK " <> Base.encode64(output) <> "\n")
                loop(gl, new_binding)

              {:error, message} ->
                payload = message <> tail(output)
                IO.write(gl, "ERR " <> Base.encode64(payload) <> "\n")
                # Keep the pre-fence binding; the doc will abort on failure anyway.
                loop(gl, binding)
            end

          true ->
            # Ignore stray input (should not happen).
            loop(gl, binding)
        end
    end
  end

  defp tail(""), do: ""
  defp tail(output), do: "\n--- captured output ---\n" <> output

  defp eval_capture(code, binding, real_gl) do
    {:ok, sio} = StringIO.open("")
    Process.group_leader(self(), sio)

    result =
      try do
        {_value, new_binding} =
          Code.eval_string(code, binding, file: "doc_fence.exs")

        {:ok, new_binding}
      rescue
        e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    Process.group_leader(self(), real_gl)
    {_input, output} = StringIO.contents(sio)
    StringIO.close(sio)
    {result, output}
  end
end

DocsVerify.EvalWorker.loop(real_gl, [])
