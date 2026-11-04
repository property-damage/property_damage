defmodule Mix.Tasks.Pd.IntegrationTest do
  # async: false because the task starts apps and prints to stdout, which we
  # capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Integration

  # A loopback HTTP server that answers 200 to every request and records the
  # request paths, so the health check runs without a live service.
  defmodule HealthServer do
    @moduledoc false

    def start do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false])
      {:ok, port} = :inet.port(listen)
      {:ok, agent} = Agent.start_link(fn -> [] end)
      spawn_link(fn -> accept_loop(listen, agent) end)
      %{port: port, agent: agent, listen: listen}
    end

    def stop(%{listen: listen, agent: agent}) do
      :gen_tcp.close(listen)
      if Process.alive?(agent), do: Agent.stop(agent)
      :ok
    end

    def base_url(%{port: port}), do: "http://127.0.0.1:#{port}"

    def paths(%{agent: agent}), do: Agent.get(agent, &Enum.reverse/1)

    defp accept_loop(listen, agent) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          path = read_path(socket, nil)
          Agent.update(agent, &[path | &1])

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

          :gen_tcp.close(socket)
          accept_loop(listen, agent)

        {:error, _} ->
          :ok
      end
    end

    defp read_path(socket, path) do
      case :gen_tcp.recv(socket, 0, 5000) do
        {:ok, {:http_request, _method, {:abs_path, p}, _version}} ->
          read_path(socket, to_string(p))

        {:ok, :http_eoh} ->
          path

        {:ok, _header} ->
          read_path(socket, path)

        {:error, _} ->
          path
      end
    end
  end

  # `run/1` halts the BEAM, so it is not testable in-process. The logic is
  # exercised through the halt-free seams instead: `result_to_code/1` (the
  # result -> exit-code mapping) and `exec/1` (returns the exit code without
  # halting; `run/1` only translates that code into `System.halt/1`). The
  # success path performs a health check over HTTP, so the `--hunt` tests answer
  # it from `HealthServer` on loopback and drive the in-process test SUT.

  describe "result_to_code/1" do
    test "0 when the run succeeded" do
      assert Integration.result_to_code({:ok, %{success: true}}) == 0
    end

    test "1 when the run failed" do
      assert Integration.result_to_code({:ok, %{success: false}}) == 1
    end

    test "0 when a bug hunt found nothing" do
      assert Integration.result_to_code({:ok, []}) == 0
    end

    test "1 when a bug hunt found bugs" do
      assert Integration.result_to_code({:ok, [%{some: :bug}]}) == 1
    end

    test "1 on an error result" do
      assert Integration.result_to_code({:error, :boom}) == 1
    end
  end

  describe "exec/1 usage errors (halt-free seam)" do
    test "returns 2 when --model is missing" do
      {code, output} = with_output(fn -> Integration.exec(["--url", "http://x"]) end)

      assert code == 2
      assert output =~ "--model is required"
    end

    test "returns 2 when --adapter is missing" do
      {code, output} =
        with_output(fn -> Integration.exec(["--model", "Some.Model", "--url", "http://x"]) end)

      assert code == 2
      assert output =~ "--adapter is required"
    end

    test "returns 2 when --url is missing (and no env var)" do
      {code, output} =
        with_output(fn ->
          Integration.exec(["--model", "Some.Model", "--adapter", "Some.Adapter"])
        end)

      assert code == 2
      assert output =~ "--url is required"
    end

    test "returns 2 for an unknown option" do
      {code, output} = with_output(fn -> Integration.exec(["--bogus", "x"]) end)

      assert code == 2
      assert output =~ "Unknown options"
    end

    test "returns 2 when the model module does not exist" do
      {code, output} =
        with_output(fn ->
          Integration.exec([
            "--model",
            "Nonexistent.Model",
            "--adapter",
            "Nonexistent.Adapter",
            "--url",
            "http://x"
          ])
        end)

      assert code == 2
      assert output =~ "Model module"
      assert output =~ "not found"
    end
  end

  describe "exec/1 --hunt" do
    setup do
      server = HealthServer.start()
      on_exit(fn -> HealthServer.stop(server) end)
      %{server: server}
    end

    test "runs the health check before the hunt", %{server: server} do
      base = HealthServer.base_url(server)

      {code, _output} =
        hunt(
          ["--model", "PropertyDamage.Test.FailingModel", "--url", base] ++
            ["--health", base <> "/health", "--hunt", "1"]
        )

      assert code == 1
      assert "/health" in HealthServer.paths(server)
    end

    test "stops after --runs runs", %{server: server} do
      base = HealthServer.base_url(server)

      # A passing SUT never yields a bug, so only --runs can end this hunt.
      {code, output} =
        hunt(
          ["--model", "PropertyDamage.Test.ExecutorModel", "--url", base] ++
            ["--health", base <> "/health", "--hunt", "1", "--runs", "2"]
        )

      assert code == 0
      assert output =~ "Reached max runs"
    end
  end

  # Run a hunt with SimpleAdapter in a task, returning {code, captured_stdout}.
  # A hunt that never ends fails the test instead of hanging the suite.
  defp hunt(args) do
    args = args ++ ["--adapter", "PropertyDamage.Test.SimpleAdapter"]
    task = Task.async(fn -> with_output(fn -> Integration.exec(args) end) end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("the hunt did not finish within 30 seconds")
    end
  end

  # Run `fun`, returning {result, captured_stdout}.
  defp with_output(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end
end
