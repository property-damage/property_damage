defmodule PropertyDamage.Log.CaptureTest do
  # Where a log line goes (DR-054): every call needs a scope, found in the
  # calling process or its `$callers`; `Runtime.log/3` writes to the same
  # place from any process; a call with no scope raises an error that names
  # the call site and the fixes; the macro accepts only literal atom tags; a
  # settle retry keeps every attempt's lines; lines never enter the event log;
  # and every framework path that runs adapter code opens a scope.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  defp compile(_context) do
    F.compile!()
    :ok
  end

  defp quiet(config), do: Map.merge(%{quiet: true}, config)

  # A module whose one function makes `call`.
  defp module_source(call) do
    name = "PropertyDamage.Test.LogFixtures.Options#{System.unique_integer([:positive])}"

    """
    defmodule #{name} do
      require PropertyDamage

      def call do
        #{call}
      end
    end
    """
  end

  # A LogAdapter config that logs in setup/1 and teardown/1 and reports
  # each call that returned.
  defp logging(name), do: %{setup_log: true, teardown_log: true, test_pid: self(), name: name}

  defp assert_logged_everywhere(name) do
    for phase <- [:setup, :execute, :teardown],
        do: assert_received({:logged, ^phase, ^name}, "no #{phase} line by #{name}")
  end

  describe "scope lookup" do
    setup :compile

    test "a line logged by a Task inside a Task sits under the step that started them, once" do
      # $callers attribution through a nested Task.
      script = %{0 => [{:nested, "nested line of step 0"}], 1 => [{:log, "own line of step 1"}]}
      report = F.report!(F.Model, [F.target("alice", quiet(%{script: script, fail_at: 2}))])
      listing = F.listing(F.plain(report), nil)

      F.assert_logs(listing, "[0]", [{"nested line of step 0", []}])
      F.assert_logs(listing, "[1]", [{"own line of step 1", []}])
      assert Enum.count(F.all_logs(listing), &(&1.message == "nested line of step 0")) == 1

      assert F.messages(F.trace_lines(report.trace, Position.prefix(0))) == [
               "nested line of step 0"
             ]
    end

    test "a GenServer logging through Runtime.log/3 with the runtime it was handed lands under that step" do
      # Runtime.log/3 from a process the adapter did not start through Task.
      script = %{
        0 => [:runtime, {:server, "server line of step 0"}],
        1 => [{:server, "server line of step 1"}]
      }

      config = quiet(%{script: script, server: true, test_pid: self(), fail_at: 2})
      report = F.report!(F.Model, [F.target("alice", config)])
      listing = F.listing(F.plain(report), nil)

      F.assert_logs(listing, "[0]", [{"server line of step 0", []}])
      F.assert_logs(listing, "[1]", [{"server line of step 1", []}])

      assert_received {:runtime, runtime}
      assert is_function(F.field(runtime, :log), 2)
    end
  end

  describe "no scope" do
    setup :compile

    test "a call from the test process raises NoScopeError naming the call site, the pid and the fixes" do
      # The no-scope error text names file:line, inspect(self()), Log.capture/1 and Runtime.log/3.
      error = F.raised(fn -> F.call(PropertyDamage.Test.LogFixtures.Outside, :call, []) end)
      assert error.__struct__ == F.no_scope_error()

      message = Exception.message(error)
      assert message =~ "#{F.source_file()}:#{F.source_line("call site: outside")}"
      assert message =~ inspect(self())
      assert message =~ "Log.capture/1"
      assert message =~ "Runtime.log/3"
    end

    test "a check that logs raises NoScopeError, and the report is a test code error" do
      # A check is not an execution point, so it has no scope.
      target = F.target("alice", %{}, F.PlainAdapter)
      report = F.report!(PropertyDamage.Test.LogFixtures.ScopelessModel, [target])

      assert report.error_origin == :test_code_error
      assert F.deep_find(report.failure_reason, &is_struct(&1, F.no_scope_error()))
    end

    @tag capture_log: true
    test "a raise inside execute/3 from an unscoped GenServer is a test code error" do
      # The server has no scope, the raise kills it, and the call exits inside execute/3.
      config = quiet(%{script: %{0 => [:no_scope_server]}})
      report = F.report!(F.Model, [F.target("alice", config)])
      text = F.plain(report)

      assert report.error_origin == :test_code_error
      assert text =~ "TEST CODE ERROR"
      assert Enum.join(F.section(text, "Failure"), "\n") =~ "Runtime.log/3"
    end
  end

  describe "macro options" do
    test "an unknown option, a non-atom tag and a non-literal opts are compile errors naming tags:" do
      # Only tags:, a literal list of atoms, is accepted.
      cases = [
        {~s{PropertyDamage.log("x", level: :debug)}, "level"},
        {~s{PropertyDamage.log("x", tags: ["http"])}, "tags"},
        {~s{opts = [tags: [:a]]\n    PropertyDamage.log("x", opts)}, "tags"}
      ]

      for {call, names} <- cases do
        result = F.compile_error(module_source(call), "log_options.exs")

        assert match?({%CompileError{}, _}, result),
               "no CompileError for #{call}: #{inspect(result)}"

        {_error, text} = result

        assert text =~ names, "#{call}: #{text}"
        assert text =~ "tags:", "#{call}: #{text}"
      end
    end

    test "a call without options and one with literal atom tags compile" do
      # The two accepted forms compile without a diagnostic.
      for call <- [~s{PropertyDamage.log("x")}, ~s{PropertyDamage.log("x", tags: [:a, :b])}] do
        assert {:ok, [_module]} = F.compile(module_source(call), "log_options.exs")
      end
    end
  end

  describe "attempts" do
    setup :compile

    test "a settle retry keeps each attempt's line, each once, with its attempt number" do
      # Every attempt kept: three attempts, three lines.
      report = F.report!(F.ProbeModel, [F.target("alice", quiet(%{fail_at: 1}))])
      listing = F.listing(F.plain(report), nil)

      F.assert_logs(listing, "[0]", [{"attempt 1", []}, {"attempt 2", []}, {"attempt 3", []}])

      lines = F.trace_lines(report.trace, Position.prefix(0))
      assert F.messages(lines) == ["attempt 1", "attempt 2", "attempt 3"]
      assert Enum.map(lines, &F.field(&1, :attempt)) == [1, 2, 3]
    end
  end

  describe "storage" do
    setup :compile

    test "lines never enter the event log, and the projections match a run that logs nothing" do
      # Lines live beside the event log, never in it.
      script = %{0 => [{:log, "a line"}, {:value, %{alice: 1}}], 1 => [{:log_http, "GET /bob"}]}
      logged = F.report!(F.Model, [F.target("alice", %{script: script, fail_at: 2})])
      plain = F.report!(F.Model, [F.target("alice", %{fail_at: 2}, F.PlainAdapter)])

      assert F.field(logged.trace, :logs, %{}) != %{}, "control: the run logged"
      refute Enum.any?(logged.trace.event_log, &is_struct(&1.event, F.line_module()))

      shape = fn report -> Enum.map(report.trace.event_log, &{&1.source, &1.event}) end
      assert shape.(logged) == shape.(plain)
      assert logged.state_at_failure == plain.state_at_failure
      assert logged.state_before_failure == plain.state_before_failure
    end

    test "each step holds its own lines, and the trace keys them by position" do
      # Step.logs and RunTrace.logs keyed by Sequence.Position.
      report = F.report!(F.Model, [F.target("alice", %{fail_at: 2})])
      steps = FailureReport.steps(report)
      assert length(steps) == 3

      for step <- steps do
        assert F.messages(F.field(step, :logs)) == ["ran act #{step.command.n} by alice"]
      end

      keys = report.trace |> F.field(:logs, %{}) |> Map.keys()
      assert Enum.all?(keys, &is_struct(&1, Position)), "keys: #{inspect(keys)}"
      assert Enum.sort(keys) == steps |> Enum.map(& &1.position) |> Enum.sort()
    end
  end

  describe "every framework path has a scope" do
    setup :compile

    test "a passing one-target run logs in setup/1, execute/3 and teardown/1 without NoScopeError" do
      # Adapter setup, execute and teardown each run in a scope.
      log =
        capture_log(fn ->
          assert {:ok, _stats} = F.run(F.Model, [F.target("alice", logging("alice"))])
        end)

      assert_logged_everywhere("alice")
      refute log =~ "NoScopeError"
    end

    test "a passing two-target run logs in every target's setup/1, execute/3 and teardown/1" do
      # The variant path opens scopes too.
      targets = [F.target("alice", logging("alice")), F.target("bob", logging("bob"))]
      log = capture_log(fn -> assert {:ok, _stats} = F.run(F.Model, targets) end)

      assert_logged_everywhere("alice")
      assert_logged_everywhere("bob")
      refute log =~ "NoScopeError"
    end

    test "the report's replay call runs a logging adapter in scopes and shows its lines" do
      # Replaying the artifact opens a scope for every adapter callback.
      dir = TmpPath.unique("pd_log_replay")
      on_exit(fn -> File.rm_rf(dir) end)
      config = %{setup_log: true, teardown_log: true, fail_at: 1}
      report = F.report!(F.Model, [F.target("alice", config)], replay_dir: dir)
      command = FailureReport.replay_command(report)
      assert is_binary(command), "control: the report has a replay call"

      call =
        String.replace_suffix(command, ")", ", replay_dir: #{inspect(Path.join(dir, "again"))})")

      log =
        capture_log(fn ->
          assert {{:error, replayed}, _binding} = Code.eval_string(call)
          assert replayed.kind == report.kind
          assert replayed.failed_at_index == report.failed_at_index

          listing = F.listing(F.plain(replayed), nil)
          F.assert_logs(listing, "[0]", [{"ran act 0 by alice", []}])
          F.assert_note_lines(listing, "adapter setup/1", "setup by alice")
        end)

      refute log =~ "NoScopeError"
    end
  end
end
