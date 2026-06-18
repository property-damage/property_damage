defmodule Mix.Tasks.Pd.ReplayTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Replay
  alias PropertyDamage.{Executor, FailureReport, Persistence, Sequence}

  # Success paths and decision logic are exercised through `exec/1`, the
  # halt-free seam: `run/1` only translates `exec/1`'s `:error` status into
  # `System.halt/1` at the boundary, so the verdict logic is testable in-process
  # without killing the test runner.

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
    test "returns :error and prints the steps and reproduce verdict", %{dir: dir} do
      path = save_failure(dir, FailingModel, FailingAdapter)

      {status, output} = with_output(fn -> Replay.exec([path]) end)

      assert status == :error
      assert output =~ "PropertyDamage Replay"
      assert output =~ "Model:    Mix.Tasks.Pd.ReplayTest.FailingModel"
      assert output =~ "[0] Bump -> OK"
      assert output =~ "[2] Bump -> FAILED (count_bounded)"
      assert output =~ "VERDICT: failure reproduces"
    end

    test "--verbose prints events and projection state", %{dir: dir} do
      path = save_failure(dir, FailingModel, FailingAdapter)

      {status, output} = with_output(fn -> Replay.exec([path, "--verbose"]) end)

      assert status == :error
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

  describe "load errors" do
    test "missing file returns :error with a clean message" do
      {status, output} = with_output(fn -> Replay.exec(["does/not/exist.pd"]) end)

      assert status == :error
      assert output =~ "could not load failure file"
      assert output =~ "file_not_found"
    end

    test "a non-.pd file returns :error", %{dir: dir} do
      bogus = Path.join(dir, "bogus.pd")
      File.write!(bogus, "not a real failure file")

      {status, output} = with_output(fn -> Replay.exec([bogus]) end)

      assert status == :error
      assert output =~ "could not load failure file"
    end
  end

  describe "branching replay" do
    test "returns :error with the branching message", %{dir: dir} do
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

      assert status == :error
      assert output =~ "parallel/branching execution"
    end
  end

  describe "argument handling" do
    test "no arguments returns :error and prints usage" do
      {status, output} = with_output(fn -> Replay.exec([]) end)

      assert status == :error
      assert output =~ "a failure file path is required"
      assert output =~ "Usage: mix pd.replay"
    end

    test "too many arguments returns :error" do
      {status, output} = with_output(fn -> Replay.exec(["a.pd", "b.pd"]) end)

      assert status == :error
      assert output =~ "expected exactly one failure file path"
    end
  end
end
