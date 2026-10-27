defmodule PropertyDamage.Log.ScopeCaptureTest do
  # `PropertyDamage.Log.capture/1` (DR-054 decision 8): a scope for code
  # outside a run. It returns the result and the lines in the order written,
  # collects into the innermost capture, covers the `Task`s started inside it,
  # lets an error out, and closes when it returns.
  use ExUnit.Case, async: true

  require PropertyDamage

  alias PropertyDamage.Test.LogFixtures, as: F

  # `capture/1` is called through `apply/3` so this file compiles before the
  # function exists.
  defp capture(fun), do: F.call(PropertyDamage.Log, :capture, [fun])

  test "returns the result and the lines in the order written" do
    {result, lines} =
      capture(fn ->
        PropertyDamage.log("first", tags: [:seed])
        PropertyDamage.log(%{alice: 100})
        :done
      end)

    assert result == :done
    assert F.messages(lines) == ["first", %{alice: 100}]
    assert [%PropertyDamage.Log.Line{tags: [:seed], attempt: 1}, %{tags: [], attempt: 1}] = lines
  end

  test "a nested capture keeps its lines and the outer one gets none of them" do
    {{_result, inner}, outer} =
      capture(fn ->
        PropertyDamage.log("outer before")
        inner = capture(fn -> PropertyDamage.log("inner") end)
        PropertyDamage.log("outer after")
        inner
      end)

    assert F.messages(inner) == ["inner"]
    assert F.messages(outer) == ["outer before", "outer after"]
  end

  test "a Task, and a Task inside a Task, started inside the capture log into it" do
    {_result, lines} =
      capture(fn ->
        Task.await(Task.async(fn -> PropertyDamage.log("from a task") end))

        Task.await(
          Task.async(fn ->
            Task.await(Task.async(fn -> PropertyDamage.log("from a task in a task") end))
          end)
        )
      end)

    assert Enum.sort(F.messages(lines)) == ["from a task", "from a task in a task"]
  end

  test "a capture inside an adapter's execute/3 keeps its lines out of the step" do
    F.compile!()
    script = %{0 => [{:capture, "inside the capture"}], 1 => [{:log, "own line of step 1"}]}
    config = %{quiet: true, script: script, test_pid: self(), fail_at: 2}
    report = F.report!(F.Model, [F.target("alice", config)])
    listing = F.listing(F.plain(report), nil)

    assert_received {:captured, captured}
    assert F.messages(captured) == ["inside the capture"]
    F.assert_logs(listing, "[0]", [])
    F.assert_logs(listing, "[1]", [{"own line of step 1", []}])
  end

  test "an error in the function propagates" do
    assert_raise RuntimeError, "boom", fn ->
      capture(fn ->
        PropertyDamage.log("lost with the error")
        raise "boom"
      end)
    end
  end

  test "a function that is not a 0-arity function raises" do
    assert_raise ArgumentError, ~r/capture/, fn -> capture(:not_a_function) end
    assert_raise ArgumentError, ~r/capture/, fn -> capture(fn _arg -> :ok end) end
  end

  test "a call after the capture returned, from a process it left running, finds no scope" do
    {task, _lines} =
      capture(fn ->
        Task.async(fn ->
          receive do
            :go ->
              try do
                PropertyDamage.log("too late")
                :logged
              rescue
                error -> error
              end
          end
        end)
      end)

    send(task.pid, :go)
    assert %{__struct__: module} = Task.await(task)
    assert module == F.no_scope_error()
  end
end
