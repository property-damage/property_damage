defmodule Mix.Tasks.Pd.IntegrationTest do
  # async: false because the task starts apps and prints to stdout, which we
  # capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Integration

  # `run/1` halts the BEAM, so it is not testable in-process. The logic is
  # exercised through the halt-free seams instead: `result_to_code/1` (the
  # result -> exit-code mapping) and `exec/1` (returns the exit code without
  # halting; `run/1` only translates that code into `System.halt/1`). The
  # success path performs real network I/O (health check + HTTP), so only the
  # usage-error paths of `exec/1` are exercised here.

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

  # Run `fun`, returning {result, captured_stdout}.
  defp with_output(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end
end
