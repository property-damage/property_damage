defmodule PropertyDamage.FlakyFailureReportTest do
  @moduledoc """
  Regression: an intermittent failure whose post-shrink re-execution does not
  reproduce must still report the reason it actually observed, not a
  contentless "Unknown Failure" with a nil reason.

  `handle_failure/N` re-executes the (shrunk) sequence to gather fresh state for
  the report. For a flaky failure that re-run can pass, leaving the fresh result
  with `success: true / failure_reason: nil / failed_at_index: nil`. Building the
  report straight from that fresh result discards the failure we observed and
  renders `[FAIL] Unknown Failure` with `Reason: nil`. The report must fall back
  to the original failing run's reason and index.

  This is the exact shape of the gitea_bench UI `CreateLabel` timeout flake: run 1
  fails with `{:adapter_error, ...}`; the confirmation re-run intermittently
  passes.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport

  defmodule Cmd do
    defstruct [:value]
    def generator(_overrides \\ %{}), do: StreamData.constant(%{value: 1})
  end

  defmodule Ev, do: defstruct([:type])

  defmodule Proj do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{count: 0}
    @impl true
    def apply(state, _event), do: %{state | count: state.count + 1}
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @impl true
    def commands, do: [Cmd]
    @impl true
    def command_sequence_projection, do: Proj
    @impl true
    def assertion_projections, do: []
  end

  # Fails (adapter error) on the very first command execution across the whole
  # run/1 lifecycle, then succeeds forever. So run 1 (exploration) fails at
  # index 0 with a real {:adapter_error, :flaky_boom}; the post-shrink re-run
  # passes -- the fresh result is success/nil, the shape that used to render as
  # "Unknown Failure". The execution counter lives in adapter_config so it
  # survives across the exploration run and the confirmation re-run.
  defmodule FlakyOnceAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, %{counter: config.counter}}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, %{counter: counter}, _runtime) do
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if n == 0 do
        {:error, :flaky_boom}
      else
        {:ok, [%Ev{type: :done}]}
      end
    end
  end

  test "a non-reproducing (flaky) failure still reports its real reason" do
    counter = :counters.new(1, [])

    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: Model,
               adapter: FlakyOnceAdapter,
               adapter_config: %{counter: counter},
               max_commands: 4,
               max_runs: 1,
               seed: 1,
               shrink: false
             )

    # The confirmation re-run passed (the counter advanced past 0), so a naive
    # report built from the fresh result would be a nil-reason "Unknown Failure".
    refute report.failure_type == :unknown,
           "expected the observed adapter error, got a contentless Unknown Failure"

    assert report.failure_type == :adapter_error
    assert report.failure_reason == {:adapter_error, :flaky_boom}
    assert report.failed_at_index == 0
  end
end
