defmodule PropertyDamage.Log.PathsTest do
  # Log lines from code the engine runs outside a command's `execute/3`
  # (DR-054 decisions 4, 5, 7 and 9): a process the adapter's `setup/1` left
  # running, an injector around a failing adapter setup on both engines, and
  # a mock told of commands and events. Each line prints once, under the point
  # that wrote it, or the call raises `PropertyDamage.Log.NoScopeError`.
  use ExUnit.Case, async: false

  alias PropertyDamage.Executor
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.LogPathFixtures, as: P

  setup do
    F.compile!()
    :ok
  end

  defp listing(report), do: report |> F.plain() |> F.listing(nil)

  describe "a process started at an inline point" do
    test "cannot log under a later point of the process that started it" do
      target = F.target("alice", %{test_pid: self(), fail_at: 1}, P.SetupTaskAdapter)
      report = F.report!(F.Model, [target])

      assert_received {:poller, {:step, 0}, :no_scope}
      assert_received {:poller, :teardown, :no_scope}

      lines = listing(report)

      assert P.log_messages(F.note_block(lines, "adapter setup/1")) ==
               ["setup by alice", "task started by setup"]

      assert P.log_messages(F.note_block(lines, "adapter teardown/1")) ==
               ["teardown by alice", "task started by teardown"]
    end

    test "cannot log under a later point on the linear engine either" do
      {:ok, result} =
        Executor.run([%F.Act{n: 0, amount: 1}], F.Model, P.SetupTaskAdapter,
          config: %{test_pid: self()}
        )

      assert_received {:poller, :teardown, :no_scope}

      assert result.logs |> Map.get(:adapter_teardown, []) |> F.messages() ==
               ["teardown by alice", "task started by teardown"]
    end
  end

  test "a process whose parent exited still logs under the step that is running" do
    target = F.target("alice", %{test_pid: self(), fail_at: 1}, P.OrphanTaskAdapter)
    report = F.report!(F.Model, [target])

    assert_received {:orphan, :logged}
    assert P.log_messages(F.block(listing(report), "[0]")) == ["logged after its parent exited"]
  end

  test "a process a finished step left running finds no scope under a later step" do
    target = F.target("alice", %{test_pid: self(), fail_at: 2}, P.LeftoverAdapter)
    report = F.report!(F.Model, [target])

    assert_received {:leftover, :no_scope}
    refute F.plain(report) =~ "left running"
  end

  test "a failed adapter setup/1 on the lockstep path tears the injector down once" do
    target = P.injected_target("alice", %{setup_log: true, fail_setup: true})
    report = F.report!(F.Model, [target])

    assert report.kind == :setup_failed
    lines = listing(report)

    assert P.log_messages(F.note_block(lines, "adapter setup/1")) ==
             ["injector setup by alice", "setup by alice"]

    assert P.log_messages(F.note_block(lines, "adapter teardown/1")) ==
             ["injector teardown by alice"]

    assert report.trace |> F.trace_lines(:adapter_teardown) |> F.messages() ==
             ["injector teardown by alice"]
  end

  test "a mock's on_command/2 and on_event/2 lines print under the step they are told of" do
    report = F.report!(F.Model, [P.mocked_target("alice", %{fail_at: 1})])

    lines = listing(report)
    assert P.log_messages(F.block(lines, "[0]")) == ["mock saw act 0", "mock saw pushed 0"]
    assert "mock saw act 1" in P.log_messages(F.block(lines, "[1]"))
  end

  test "a scope reads the same from one dictionary key and from the whole dictionary" do
    # The whole-dictionary read is the fallback where the one-key read is
    # missing (OTP before 26.2); both reads must agree on every process.
    parent = self()
    writer = fn _message, _opts -> :ok end

    holder =
      spawn(fn ->
        PropertyDamage.Log.with_scope(writer, fn ->
          send(parent, :scoped)
          receive do: (:done -> :ok)
        end)
      end)

    bare = spawn(fn -> receive do: (:done -> :ok) end)
    dead = spawn(fn -> :ok end)
    assert_receive :scoped
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    assert {^writer, token} = PropertyDamage.Log.scope_in(holder, :dictionary)
    assert is_pid(token)
    assert PropertyDamage.Log.scope_in(holder, :key) == {writer, token}
    assert PropertyDamage.Log.scope_in(bare, :dictionary) == nil
    assert PropertyDamage.Log.scope_in(bare, :key) == nil
    assert PropertyDamage.Log.scope_in(dead, :dictionary) == :dead
    assert PropertyDamage.Log.scope_in(dead, :key) == :dead

    for pid <- [holder, bare], do: send(pid, :done)
  end

  test "a binary message that is not valid UTF-8 prints through inspect" do
    script = %{0 => [{:value, <<255, 254, 0>>}]}
    report = F.report!(F.Model, [F.target("alice", %{quiet: true, fail_at: 1, script: script})])

    text = F.plain(report)
    assert String.valid?(text)
    assert P.log_messages(F.block(F.listing(text, nil), "[0]")) == ["<<255, 254, 0>>"]
  end
end
