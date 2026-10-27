defmodule PropertyDamage.Log.PathsTest do
  # Log lines from code the engine runs outside a command's `execute/3`
  # (DR-054 decisions 4, 5, 7 and 9): a process the adapter's `setup/1` left
  # running, an injector around a failing adapter setup on both engines, a
  # nemesis fault the end of a failed run lifts, and a mock told of commands
  # and events. Each line prints once, under the point that wrote it, or the
  # call raises `PropertyDamage.Log.NoScopeError`.
  use ExUnit.Case, async: false

  alias PropertyDamage.Executor
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.LogPathFixtures, as: P

  setup do
    F.compile!()
    :ok
  end

  defp listing(report), do: report |> F.plain() |> F.listing(nil)

  defp all_messages(logs), do: logs |> Map.values() |> List.flatten() |> F.messages()

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

  test "a failed adapter setup/1 on the branching path keeps its setup and service lines" do
    target = P.injected_target("alice", %{setup_log: true, fail_setup: true})

    branching = [
      branching: [branch_probability: 1.0, max_branches: 2, min_prefix_length: 1],
      max_commands: 4
    ]

    report = F.report!(F.Model, [target], branching)

    assert report.kind == :setup_failed
    lines = listing(report)

    assert P.log_messages(F.note_block(lines, "adapter setup/1") || []) ==
             ["injector setup by alice", "setup by alice"]

    assert P.log_messages(F.note_block(lines, "adapter teardown/1") || []) ==
             ["injector teardown by alice"]
  end

  describe "a nemesis fault still active when the run fails" do
    test "prints its end-of-run restore/2 line under the injecting step" do
      target = F.target("alice", %{quiet: true, fail_at: 1})
      report = F.report!(P.FaultModel, [target], max_commands: 4)

      lines = listing(report)
      assert P.log_messages(F.block(lines, "[0]")) == ["inject short", "restore short"]
      assert P.log_messages(F.block(lines, "[1]")) == ["inject long", "restore long"]
    end

    test "keeps its end-of-run restore/2 line on the linear engine" do
      commands = [
        %P.Fault{tag: :short, duration_ms: 0},
        %P.Fault{tag: :long, duration_ms: 600_000},
        %F.Act{n: 0, amount: 1},
        %F.Act{n: 1, amount: 1}
      ]

      {:ok, result} =
        Executor.run(commands, P.FaultModel, F.log_adapter(),
          config: %{name: "alice", quiet: true, fail_at: 1}
        )

      refute result.success
      assert Enum.count(all_messages(result.logs), &(&1 == "restore long")) == 1
    end
  end

  test "a mock's on_command/2 and on_event/2 lines print under the step they are told of" do
    report = F.report!(F.Model, [P.mocked_target("alice", %{fail_at: 1})])

    lines = listing(report)
    assert P.log_messages(F.block(lines, "[0]")) == ["mock saw act 0", "mock saw pushed 0"]
    assert "mock saw act 1" in P.log_messages(F.block(lines, "[1]"))
  end

  test "a binary message that is not valid UTF-8 prints through inspect" do
    script = %{0 => [{:value, <<255, 254, 0>>}]}
    report = F.report!(F.Model, [F.target("alice", %{quiet: true, fail_at: 1, script: script})])

    text = F.plain(report)
    assert String.valid?(text)
    assert P.log_messages(F.block(F.listing(text, nil), "[0]")) == ["<<255, 254, 0>>"]
  end
end
