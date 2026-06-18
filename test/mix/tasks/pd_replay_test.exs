defmodule Mix.Tasks.Pd.ReplayTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Replay
  alias PropertyDamage.{Executor, FailureReport, Persistence, Sequence}

  # Success paths and decision logic are exercised through `exec/1`, the
  # halt-free seam: `run/1` only translates `exec/1`'s status into a
  # `System.halt/1` exit code at the boundary, so the verdict logic is testable
  # in-process without killing the test runner. The statuses map to exit codes:
  # `:ok` -> 0, `:reproduces` -> 1, `:indeterminate` -> 125, `:usage_error` -> 2.
  # The `:indeterminate`/125 split is what makes `git bisect run mix pd.replay`
  # skip un-runnable commits instead of marking them bad.

  # ----------------------------------------------------------------------------
  # Fixtures. A counter that fails its invariant on the 3rd bump (the failing
  # SUT), plus a "fixed" variant whose bump is a no-op so the invariant holds.
  # ----------------------------------------------------------------------------

  defmodule Counted do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Bump do
    @moduledoc false
    @behaviour PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Counter do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %Counted{amount: n}), do: %{state | count: state.count + n}
    def apply(state, _), do: state

    @trigger every: 1
    def count_bounded(state, _cmd_or_event) do
      if state.count >= 3 do
        PropertyDamage.fail!("count exceeded bound", count: state.count)
      end
    end
  end

  defmodule FailingAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, %{config: config}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Bump{}, _context), do: {:ok, [%Counted{amount: 1}]}
  end

  defmodule FixedAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, %{config: config}}

    @impl true
    def teardown(_context), do: :ok

    # The "bug" is fixed: a bump no longer increments, so the invariant holds.
    @impl true
    def execute(%Bump{}, _context), do: {:ok, [%Counted{amount: 0}]}
  end

  defmodule FailingModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter
  end

  defmodule FixedModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "pd_replay_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Record a real 3-bump failure against `adapter`, package it as a FailureReport
  # naming `model`/`adapter`, and save it to `dir`. Returns the file path.
  defp save_failure(dir, model, adapter) do
    sequence = Sequence.linear([%Bump{}, %Bump{}, %Bump{}])
    {:ok, result} = Executor.run(sequence, FailingModel, FailingAdapter, [])

    failure =
      FailureReport.new(
        seed: 0,
        run_number: 1,
        original_sequence: sequence,
        shrunk_sequence: sequence,
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        event_log: result.event_log,
        projections: result.projections,
        projections_before: result.projections_before,
        model: model,
        adapter: adapter
      )

    {:ok, path} = Persistence.save(failure, dir)
    path
  end

  # Run `fun`, returning {status, captured_stdout}.
  defp with_output(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:status, fun.()}) end)
    assert_received {:status, status}
    {status, output}
  end

  describe "happy path: the bug still reproduces" do
    test "returns :reproduces and prints the steps and reproduce verdict", %{dir: dir} do
      path = save_failure(dir, FailingModel, FailingAdapter)

      {status, output} = with_output(fn -> Replay.exec([path]) end)

      assert status == :reproduces
      assert output =~ "PropertyDamage Replay"
      assert output =~ "Model:    Mix.Tasks.Pd.ReplayTest.FailingModel"
      assert output =~ "[0] Bump -> OK"
      assert output =~ "[2] Bump -> FAILED (count_bounded)"
      assert output =~ "VERDICT: failure reproduces"
    end

    test "--verbose prints events and projection state", %{dir: dir} do
      path = save_failure(dir, FailingModel, FailingAdapter)

      {status, output} = with_output(fn -> Replay.exec([path, "--verbose"]) end)

      assert status == :reproduces
      assert output =~ "events: Counted"
      assert output =~ "state:"
      assert output =~ "count: "
    end
  end

  describe "fixed SUT: the bug no longer reproduces" do
    test "returns :ok and prints the fixed verdict", %{dir: dir} do
      path = save_failure(dir, FixedModel, FixedAdapter)

      {status, output} = with_output(fn -> Replay.exec([path]) end)

      assert status == :ok
      assert output =~ "[0] Bump -> OK"
      assert output =~ "[2] Bump -> OK"
      assert output =~ "VERDICT: failure no longer reproduces"
    end
  end

  # The "could-not-run" set (load error, branching, missing model/adapter) is
  # indeterminate: the bug's presence cannot be decided, so these map to
  # `:indeterminate` (exit 125 -> `git bisect` skip), NOT to `:reproduces`.
  # Marking an un-runnable ancestor "bad" would corrupt a bisect.
  describe "indeterminate: the replay could not run (exit 125 -> bisect skip)" do
    test "missing file returns :indeterminate with a clean message" do
      {status, output} = with_output(fn -> Replay.exec(["does/not/exist.pd"]) end)

      assert status == :indeterminate
      assert output =~ "could not load failure file"
      assert output =~ "file_not_found"
    end

    test "a non-.pd file returns :indeterminate", %{dir: dir} do
      bogus = Path.join(dir, "bogus.pd")
      File.write!(bogus, "not a real failure file")

      {status, output} = with_output(fn -> Replay.exec([bogus]) end)

      assert status == :indeterminate
      assert output =~ "could not load failure file"
    end

    test "a branching (parallel) failure returns :indeterminate", %{dir: dir} do
      branching = %Sequence{prefix: [%Bump{}], branches: [[%Bump{}], [%Bump{}]], suffix: []}

      failure =
        FailureReport.new(
          seed: 0,
          run_number: 1,
          original_sequence: branching,
          shrunk_sequence: branching,
          failed_at_index: 1,
          failure_reason: {:assertion_failed, :count_bounded, %RuntimeError{message: "x"}},
          model: FailingModel,
          adapter: FailingAdapter
        )

      {:ok, path} = Persistence.save(failure, dir)

      {status, output} = with_output(fn -> Replay.exec([path]) end)

      assert status == :indeterminate
      assert output =~ "parallel/branching execution"
    end

    test "a failure that records no model returns :indeterminate", %{dir: dir} do
      sequence = Sequence.linear([%Bump{}, %Bump{}, %Bump{}])

      failure =
        FailureReport.new(
          seed: 0,
          run_number: 1,
          original_sequence: sequence,
          shrunk_sequence: sequence,
          failed_at_index: 2,
          failure_reason: {:assertion_failed, :count_bounded, %RuntimeError{message: "x"}},
          model: nil,
          adapter: FailingAdapter
        )

      {:ok, path} = Persistence.save(failure, dir)

      {status, output} = with_output(fn -> Replay.exec([path]) end)

      assert status == :indeterminate
      assert output =~ "does not record a model"
    end
  end

  describe "argument handling (usage errors exit 2)" do
    test "no arguments returns :usage_error and prints usage" do
      {status, output} = with_output(fn -> Replay.exec([]) end)

      assert status == :usage_error
      assert output =~ "a failure file path is required"
      assert output =~ "Usage: mix pd.replay"
    end

    test "too many arguments returns :usage_error" do
      {status, output} = with_output(fn -> Replay.exec(["a.pd", "b.pd"]) end)

      assert status == :usage_error
      assert output =~ "expected exactly one failure file path"
    end

    test "an unknown option returns :usage_error" do
      {status, output} = with_output(fn -> Replay.exec(["a.pd", "--nope"]) end)

      assert status == :usage_error
      assert output =~ "invalid option"
    end
  end
end
