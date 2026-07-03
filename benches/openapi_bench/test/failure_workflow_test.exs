defmodule OpenapiBench.FailureWorkflowTest do
  @moduledoc """
  End-to-end acceptance test for the failure-handling path, and specifically the
  honest proof of `PropertyDamage.Export.HTTPSpec`: a failure discovered by the
  generated client (via the scaffold-emitted `http_spec/2` on
  `OpenapiBench.Generated.Adapter`, no hand-written glue) is

    1. persisted to a `.pd` file (+ a generated ExUnit regression test) by the
       `PropertyDamage.Regression` handler,
    2. reloaded from disk and replayed, reproducing the check failure,
    3. exported to a standalone **curl** script, which is then **executed**
       against the live bench API and reproduces the dropped-write bug.

  Step 3 is the only end-to-end proof that the exported script actually drives
  the same HTTP calls that expose the bug. It is paired with a control run of
  the same script against the *faithful* SUT, which does not reproduce it (so
  the reproduction signal is real, not an artifact of the script always failing).
  """
  use ExUnit.Case, async: false

  alias OpenapiBench.Generated.Adapter
  alias OpenapiBench.Generated.Commands.{GetValue, PutValue}
  alias OpenapiBench.Generated.Model
  alias OpenapiBench.Server

  @moduletag timeout: 120_000

  setup do
    dir = Path.join(System.tmp_dir!(), "openapi_bench_wf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "seeded bug: persist -> replay from disk -> execute exported curl reproduces", %{dir: dir} do
    failures_dir = Path.join(dir, "failures")
    tests_dir = Path.join(dir, "regressions")

    # (a) Trigger the seeded bug, (b) persist via the Regression handler.
    assert {:error, _report} =
             PropertyDamage.run(
               model: Model,
               adapter: Adapter,
               adapter_config: %{base_url: Server.base_url(), bug: true},
               # The run-level :regression schema accepts :adapter, so the
               # generated ExUnit test's HTTP-spec mapping is pinned explicitly
               # to the generated adapter rather than falling back to
               # report.adapter.
               regression: [
                 save_failures: failures_dir,
                 generate_tests: tests_dir,
                 adapter: Adapter
               ],
               max_commands: 25,
               max_runs: 50,
               seed: 1,
               verbose: false
             )

    # The handler saved a .pd failure file and generated an ExUnit test.
    assert [pd_path] = Path.wildcard(Path.join(failures_dir, "*.pd"))
    assert [exunit_path] = Path.wildcard(Path.join(tests_dir, "*.exs"))
    # The generated regression test is syntactically valid Elixir.
    assert {:ok, _ast} = exunit_path |> File.read!() |> Code.string_to_quoted()

    # (c) Reload from disk and confirm it is the minimal repro.
    assert {:ok, loaded} = PropertyDamage.load_failure(pd_path)

    shrunk =
      loaded
      |> PropertyDamage.FailureReport.shrunk_sequence()
      |> PropertyDamage.Sequence.to_list()

    assert [%PutValue{key: key}, %GetValue{key: key}] = shrunk

    # Replaying the reloaded failure against the buggy SUT reproduces the check
    # failure (drives the same engine path as the original run).
    assert {:ok, steps} =
             PropertyDamage.replay(loaded,
               adapter_config: %{base_url: Server.base_url(), bug: true}
             )

    assert Enum.any?(steps, &match?({:check_failed, _, _}, &1.result)),
           "expected the replayed sequence to reproduce the read-consistency failure"

    # (d) Export a curl script and EXECUTE it against the live API. The script
    # replays the raw HTTP calls; it does not reset the SUT, so we seed the bug
    # flag first, then assert the exported GET observes the dropped write.
    script_path = Path.join(dir, "reproduce.sh")

    script =
      PropertyDamage.Export.to_script(loaded, :curl,
        base_url: Server.base_url(),
        adapter: Adapter
      )

    File.write!(script_path, script)

    # The generated client's HTTP mapping was actually used (no missing-spec
    # placeholder leaked into the script).
    refute script =~ "no HTTPSpec available"
    assert script =~ "curl -s"

    Server.reset(true)
    {buggy_out, 0} = System.cmd("bash", [script_path], stderr_to_stdout: true)

    assert buggy_out =~ "not_found",
           "exported curl should reproduce the dropped write (GET 404 not_found)\n#{buggy_out}"

    # Control: the same script against a faithful SUT does NOT reproduce it.
    Server.reset(false)
    {faithful_out, 0} = System.cmd("bash", [script_path], stderr_to_stdout: true)

    refute faithful_out =~ "not_found",
           "against a faithful SUT the write persists, so no reproduction\n#{faithful_out}"
  end
end
