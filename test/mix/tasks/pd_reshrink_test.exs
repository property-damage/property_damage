defmodule Mix.Tasks.Pd.ReshrinkTest do
  # async: false because the task runs the "compile" Mix task and prints to
  # stdout, which we capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Reshrink
  alias PropertyDamage.{Executor, FailureReport, Persistence, Sequence}

  # The decision logic is exercised through `exec/1`, the halt-free seam: `run/1`
  # only translates `exec/1`'s `:error` status into `System.halt/1` at the
  # boundary, so re-shrink behaviour is testable in-process.

  # ----------------------------------------------------------------------------
  # Fixture: a counter whose invariant fails once the count reaches 3. Every Bump
  # increments by 1, so the minimal reproduction is exactly 3 Bumps. A saved
  # sequence longer than 3 therefore has something for re-shrink to remove.
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
    def execute(%Bump{}, _context, _runtime), do: {:ok, [%Counted{amount: 1}]}
  end

  defmodule FailingModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "pd_reshrink_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Save a FailureReport whose shrunk_sequence is `commands` Bumps long. The
  # executor stops at the first failing index (the 3rd Bump), so the report's
  # failed_at_index/failure_reason are the real ones, but the saved sequence is
  # deliberately as long as `length` so re-shrink has slack to remove.
  defp save_failure(dir, length, opts \\ []) do
    sequence = Sequence.linear(List.duplicate(%Bump{}, length))
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
        model: Keyword.get(opts, :model, FailingModel),
        adapter: Keyword.get(opts, :adapter, FailingAdapter)
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

  describe "happy path: a non-minimal failure reduces" do
    test "returns :ok and prints the before/after reduction", %{dir: dir} do
      path = save_failure(dir, 8)

      {status, output} = with_output(fn -> Reshrink.exec([path]) end)

      assert status == :ok
      assert output =~ "PropertyDamage Re-shrink"
      assert output =~ "Before:     8 commands"
      assert output =~ "After:      3 commands"
      assert output =~ "Reduced 8 -> 3 commands"
    end

    test "writes nothing by default", %{dir: dir} do
      path = save_failure(dir, 8)
      before = File.ls!(dir)

      {status, output} = with_output(fn -> Reshrink.exec([path]) end)

      assert status == :ok
      assert output =~ "Pass --output PATH or --overwrite to save"
      assert File.ls!(dir) == before
    end

    test "--output writes a smaller, loadable report", %{dir: dir} do
      path = save_failure(dir, 8)
      out = Path.join(dir, "smaller.pd")

      {status, output} = with_output(fn -> Reshrink.exec([path, "--output", out]) end)

      assert status == :ok
      assert output =~ "Wrote re-shrunk failure to #{out}"
      assert File.exists?(out)

      {:ok, reloaded} = PropertyDamage.load_failure(out)
      assert length(Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(reloaded))) == 3
    end

    test "--overwrite replaces the input file in place", %{dir: dir} do
      path = save_failure(dir, 8)

      {status, output} = with_output(fn -> Reshrink.exec([path, "--overwrite"]) end)

      assert status == :ok
      assert output =~ "Wrote re-shrunk failure to #{path}"

      {:ok, reloaded} = PropertyDamage.load_failure(path)
      assert length(Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(reloaded))) == 3
    end
  end

  describe "already minimal" do
    test "returns :ok and reports no further reduction", %{dir: dir} do
      path = save_failure(dir, 3)

      {status, output} = with_output(fn -> Reshrink.exec([path]) end)

      assert status == :ok
      assert output =~ "Before:     3 commands"
      assert output =~ "After:      3 commands"
      assert output =~ "Already minimal under this budget"
    end
  end

  describe "errors" do
    test "missing model/adapter returns :error with a clean message", %{dir: dir} do
      path = save_failure(dir, 8, model: nil)

      {status, output} = with_output(fn -> Reshrink.exec([path]) end)

      assert status == :error
      assert output =~ "does not record a model and adapter"
    end

    test "missing file returns :error with a clean message" do
      {status, output} = with_output(fn -> Reshrink.exec(["does/not/exist.pd"]) end)

      assert status == :error
      assert output =~ "could not load failure file"
      assert output =~ "file_not_found"
    end

    test "an unknown strategy returns :error before doing any work" do
      {status, output} = with_output(fn -> Reshrink.exec(["x.pd", "--strategy", "nope"]) end)

      assert status == :error
      assert output =~ "unknown strategy"
    end
  end

  describe "branching" do
    test "re-shrinks a branching failure without a branching guard", %{dir: dir} do
      branching = %Sequence{prefix: [%Bump{}], branches: [[%Bump{}], [%Bump{}]], suffix: []}
      {:ok, result} = Executor.run(branching, FailingModel, FailingAdapter, [])

      failure =
        FailureReport.new(
          seed: 0,
          run_number: 1,
          original_sequence: branching,
          shrunk_sequence: branching,
          failed_at_index: result.failed_at_index,
          failure_reason: result.failure_reason,
          event_log: result.event_log,
          projections: result.projections,
          projections_before: result.projections_before,
          model: FailingModel,
          adapter: FailingAdapter
        )

      {:ok, path} = Persistence.save(failure, dir)

      {status, output} = with_output(fn -> Reshrink.exec([path]) end)

      assert status == :ok
      refute output =~ "branching"
      refute output =~ "could not run"
    end
  end

  describe "argument handling" do
    test "no arguments returns :error and prints usage" do
      {status, output} = with_output(fn -> Reshrink.exec([]) end)

      assert status == :error
      assert output =~ "a failure file path is required"
      assert output =~ "Usage: mix pd.reshrink"
    end

    test "too many arguments returns :error" do
      {status, output} = with_output(fn -> Reshrink.exec(["a.pd", "b.pd"]) end)

      assert status == :error
      assert output =~ "expected exactly one failure file path"
    end
  end

  describe "ANSI gating (I2)" do
    test "emits no ANSI escape bytes when IO.ANSI is disabled" do
      previous = Application.get_env(:elixir, :ansi_enabled)
      Application.put_env(:elixir, :ansi_enabled, false)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:elixir, :ansi_enabled)
        else
          Application.put_env(:elixir, :ansi_enabled, previous)
        end
      end)

      {_status, output} = with_output(fn -> Reshrink.exec([]) end)

      assert output =~ "a failure file path is required"
      refute output =~ "\e[", "task leaked ANSI escapes with color disabled"
    end
  end
end
