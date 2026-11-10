defmodule PropertyDamage.ReportBuilderCharacterizationTest do
  @moduledoc """
  Pins which report fields each failure path sets, through real tiny failing
  runs: a failure as the run found it, a failure after shrinking, a failure
  across two targets, a latency-budget breach, and a further shrink. A path
  that stops setting a field, or sets it differently, fails here.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Sequence}

  @seed 4_321

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

  # Fails once the count reaches 3, and exposes the count to `@compare`.
  defmodule Counter do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %Counted{amount: n}), do: %{state | count: state.count + n}
    def apply(state, _), do: state

    @check every: 1
    def count_bounded(state, _cmd_or_event) do
      state.count < 3 or PropertyDamage.fail!("count exceeded bound", count: state.count)
    end

    @compare every: 1
    def count(state, _root), do: state.count
  end

  defmodule Adapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, %{config: config}}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Bump{}, _context, _runtime), do: {:ok, [%Counted{amount: 1}]}
  end

  defmodule Model do
    @moduledoc false
    use PropertyDamage.Model

    @impl true
    def commands, do: [Bump]

    @impl true
    def command_sequence_projection, do: Counter

    @impl true
    def check_projections, do: [Counter]
  end

  # Runs that fail: the counter passes 3 within `max_commands: 6` commands.
  defp failing_run(extra) do
    [
      model: Model,
      targets: [{Adapter, []}],
      max_runs: 1,
      max_commands: 6,
      seed: @seed,
      replay_dir: false
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  defp two_targets,
    do: [{Adapter, name: "a", config: %{tenant: 1}}, {Adapter, name: "b", config: %{tenant: 2}}]

  @counter PropertyDamage.ReportBuilderCharacterizationTest.Counter
  @fired {@counter, :count_bounded}
  @compared {@counter, :count}

  # The fields a report path sets, less what varies from run to run (the run
  # nonce, the source revision, elapsed time, the epoch of a shrunk run).
  defp pinned(%FailureReport{trace: trace} = report) do
    %{
      kind: report.report_kind,
      plan_source: trace.plan_source,
      seed: FailureReport.seed(report),
      run_number: FailureReport.run_number(report),
      failed_at_index: report.failed_at_index,
      original_failed_at_index: report.original_failed_at_index,
      variant: report.variant,
      shrink_iterations: report.shrink_iterations,
      shrink_stop: report.shrink_stop,
      original_length: length(Sequence.to_list(report.original_sequence)),
      shrunk_length: length(Sequence.to_list(FailureReport.shrunk_sequence(report))),
      check_fires: report.check_fires,
      run_check_fires: report.run_check_fires,
      compare_counts: report.compare_counts,
      other_failures: report.other_failures,
      expansion_counts: report.expansion_counts,
      expansions:
        Map.new(report.expansions || %{}, fn {name, roots} -> {name, length(roots)} end),
      has_trace_expansion: is_map(trace.expansion),
      latency: report.latency,
      has_metrics: is_map(report.metrics),
      campaign: report.campaign,
      concurrency: report.concurrency,
      check_mode: report.check_mode,
      stutter: report.stutter,
      max_commands: report.max_commands,
      target_names: Enum.map(report.targets, fn {_adapter, opts} -> opts[:name] end),
      executed_roots: map_size(trace.executed),
      event_log_length: length(trace.event_log),
      fold_ordinals: map_size(trace.command_fold_ordinals),
      has_stacktrace: report.stacktrace != nil,
      logs: trace.logs
    }
  end

  defp assert_run_inputs(%FailureReport{trace: trace}) do
    assert is_integer(trace.run_nonce)
    assert {revision, dirty?} = trace.source_revision
    assert is_binary(revision) and is_boolean(dirty?)
  end

  describe "a failure as the run found it" do
    test "sets the unshrunk fields, generated plan and epoch 1" do
      assert {:error, %FailureReport{} = report} = failing_run(shrink: false)
      assert_run_inputs(report)
      assert report.trace.mint_epoch == 1
      assert report.shrink_time_ms == 0

      assert pinned(report) == %{
               kind: :check_failed,
               plan_source: :generated,
               seed: @seed,
               run_number: 1,
               failed_at_index: 2,
               original_failed_at_index: 2,
               variant: %{index: 0, name: "Adapter"},
               shrink_iterations: 0,
               shrink_stop: :done,
               original_length: 6,
               shrunk_length: 6,
               check_fires: %{@fired => 5},
               run_check_fires: %{@fired => 5},
               compare_counts: %{@compared => %{waited_ms: 0, compared_at: 0, waited_at: 0}},
               other_failures: [],
               expansion_counts: %{"Adapter" => %{}},
               expansions: %{"Adapter" => 3},
               has_trace_expansion: true,
               latency: false,
               has_metrics: false,
               campaign: nil,
               concurrency: :serial,
               check_mode: :halt,
               stutter: nil,
               max_commands: 6,
               target_names: ["Adapter"],
               executed_roots: 3,
               event_log_length: 3,
               fold_ordinals: 3,
               has_stacktrace: true,
               logs: %{}
             }
    end

    test "carries each target's entry and result across two targets" do
      assert {:error, %FailureReport{} = report} =
               failing_run(shrink: false, targets: two_targets())

      pinned = pinned(report)
      assert pinned.target_names == ["a", "b"]
      assert pinned.variant == %{index: 0, name: "a"}
      assert pinned.expansion_counts == %{"a" => %{}, "b" => %{}}
      assert pinned.expansions == %{"a" => 3, "b" => 3}

      assert pinned.compare_counts == %{
               @compared => %{waited_ms: 0, compared_at: 2, waited_at: 0}
             }

      assert pinned.other_failures == []
    end
  end

  describe "a failure after shrinking" do
    test "reports the shrunk reproduction with its own plan source and counts" do
      assert {:error, %FailureReport{} = report} = failing_run([])
      assert_run_inputs(report)
      assert report.trace.mint_epoch > 1
      assert report.shrink_time_ms >= 0

      assert %{
               kind: :check_failed,
               plan_source: :shrunk,
               failed_at_index: 2,
               original_failed_at_index: 2,
               shrink_iterations: 4,
               shrink_stop: :done,
               original_length: 6,
               shrunk_length: 3,
               check_fires: %{@fired => 5},
               run_check_fires: %{@fired => 5},
               expansions: %{"Adapter" => 3},
               has_trace_expansion: true,
               executed_roots: 3,
               event_log_length: 3,
               fold_ordinals: 3
             } = pinned(report)
    end
  end

  describe "a latency budget breach" do
    test "reports the last run, unlocalized and never shrunk" do
      assert {:error, %FailureReport{} = report} =
               PropertyDamage.run(
                 model: Model,
                 targets: two_targets(),
                 max_runs: 2,
                 max_commands: 2,
                 seed: @seed,
                 latency: [p95: [max_ratio: 1.0e-9]],
                 replay_dir: false
               )

      assert_run_inputs(report)
      assert report.trace.mint_epoch == 0
      assert report.shrink_time_ms == 0

      assert pinned(report) == %{
               kind: :latency_exceeded,
               plan_source: :generated,
               seed: 377_557_814,
               run_number: 2,
               failed_at_index: nil,
               original_failed_at_index: nil,
               variant: %{index: 1, name: "b"},
               shrink_iterations: 0,
               shrink_stop: :done,
               original_length: 2,
               shrunk_length: 2,
               check_fires: %{@fired => 8},
               run_check_fires: %{},
               compare_counts: %{@compared => %{waited_ms: 0, compared_at: 4, waited_at: 0}},
               other_failures: [],
               expansion_counts: %{},
               expansions: %{},
               has_trace_expansion: false,
               latency: [p95: [max_ratio: 1.0e-9]],
               has_metrics: true,
               campaign: %{seed: @seed, max_runs: 2},
               concurrency: :serial,
               check_mode: :halt,
               stutter: nil,
               max_commands: 2,
               target_names: ["a", "b"],
               executed_roots: 2,
               event_log_length: 2,
               fold_ordinals: 2,
               has_stacktrace: false,
               logs: %{}
             }
    end

    test "lists every other breaching target as an other failure" do
      targets =
        for {name, tenant} <- [{"a", 1}, {"b", 2}, {"c", 3}],
            do: {Adapter, name: name, config: %{tenant: tenant}}

      assert {:error, %FailureReport{} = report} =
               PropertyDamage.run(
                 model: Model,
                 targets: targets,
                 max_runs: 2,
                 max_commands: 2,
                 seed: @seed,
                 latency: [p95: [max_ratio: 1.0e-9]],
                 replay_dir: false
               )

      assert report.variant == %{index: 1, name: "b"}

      assert [%{variant: %{index: 2, name: "c"}, root: nil, failure: %Failure{}}] =
               report.other_failures
    end
  end

  describe "a further shrink" do
    test "folds the new effort into the report it re-shrinks" do
      assert {:error, %FailureReport{} = report} = failing_run([])
      assert {:ok, %FailureReport{} = further} = PropertyDamage.shrink_further(report)
      assert_run_inputs(further)

      assert further.trace.run_nonce == report.trace.run_nonce
      assert further.trace.mint_epoch > 0
      assert further.shrink_iterations > report.shrink_iterations
      assert further.shrink_time_ms >= report.shrink_time_ms

      assert %{
               kind: :check_failed,
               plan_source: :shrunk,
               seed: @seed,
               run_number: 1,
               failed_at_index: 2,
               original_failed_at_index: 2,
               variant: %{index: 0, name: "Adapter"},
               shrink_stop: :done,
               original_length: 6,
               shrunk_length: 3,
               check_fires: %{@fired => 5},
               run_check_fires: %{@fired => 5},
               compare_counts: %{@compared => %{waited_ms: 0, compared_at: 0, waited_at: 0}},
               other_failures: [],
               expansions: %{},
               has_trace_expansion: false,
               latency: false,
               has_metrics: false,
               campaign: nil,
               concurrency: :serial,
               check_mode: :halt,
               stutter: nil,
               max_commands: 6,
               target_names: ["Adapter"],
               executed_roots: 3,
               event_log_length: 3,
               fold_ordinals: 3,
               has_stacktrace: true,
               logs: %{}
             } = pinned(further)
    end
  end
end
