defmodule PropertyDamage.ShrinkFurtherTest do
  @moduledoc """
  Direct coverage for `PropertyDamage.shrink_further/2`, the engine path that
  `mix pd.reshrink` exposes. It re-runs the shrinker over an already-shrunk
  sequence with a fresh budget and folds the new effort into the report.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, FailureReport, Sequence}

  # A counter whose invariant fails once the count reaches 3. Each Bump adds 1,
  # so the minimal reproduction is exactly 3 Bumps; anything longer is reducible.

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

  defmodule FailingModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter
  end

  defp report_of_length(length, overrides \\ []) do
    sequence = Sequence.linear(List.duplicate(%Bump{}, length))
    {:ok, result} = Executor.run(sequence, FailingModel, FailingAdapter, [])

    FailureReport.new(
      [
        seed: 0,
        run_number: 1,
        original_sequence: sequence,
        shrunk_sequence: sequence,
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        event_log: result.event_log,
        projections: result.projections,
        projections_before: result.projections_before,
        shrink_iterations: 7,
        shrink_time_ms: 11,
        model: FailingModel,
        adapter: FailingAdapter
      ]
      |> Keyword.merge(overrides)
    )
  end

  test "reduces a non-minimal sequence to the minimal reproduction" do
    report = report_of_length(8)
    assert length(Sequence.to_list(report.shrunk_sequence)) == 8

    assert {:ok, smaller} = PropertyDamage.shrink_further(report)
    assert length(Sequence.to_list(smaller.shrunk_sequence)) == 3
  end

  test "accumulates shrink_iterations and shrink_time_ms onto the prior report" do
    report = report_of_length(8)

    assert {:ok, smaller} = PropertyDamage.shrink_further(report)

    # The prior report carried 7 iterations / 11 ms; re-shrinking adds to those.
    assert smaller.shrink_iterations >= report.shrink_iterations
    assert smaller.shrink_iterations > 7
    assert smaller.shrink_time_ms >= 11
  end

  test "preserves the original_sequence" do
    report = report_of_length(8)

    assert {:ok, smaller} = PropertyDamage.shrink_further(report)
    assert smaller.original_sequence == report.original_sequence
  end

  test "honours an explicit strategy and budget" do
    report = report_of_length(8)

    assert {:ok, smaller} =
             PropertyDamage.shrink_further(report, strategy: :exhaustive, max_iterations: 1000)

    assert length(Sequence.to_list(smaller.shrunk_sequence)) == 3
  end

  test "returns {:error, :missing_model_or_adapter} when the model is nil" do
    report = report_of_length(8, model: nil)
    assert {:error, :missing_model_or_adapter} = PropertyDamage.shrink_further(report)
  end

  test "returns {:error, :missing_model_or_adapter} when the adapter is nil" do
    report = report_of_length(8, adapter: nil)
    assert {:error, :missing_model_or_adapter} = PropertyDamage.shrink_further(report)
  end
end
