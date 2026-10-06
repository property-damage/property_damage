defmodule PropertyDamage.ComparisonTest do
  use ExUnit.Case, async: true

  # Module-function telemetry handler (avoids the local-function performance
  # warning telemetry logs for anonymous handlers).
  def forward_telemetry(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{RunResult, RunUpdate}

  # ============================================================================
  # Test Support - Adapters
  # ============================================================================

  defmodule TestEvent do
    defstruct [:value, :item_ref, :id, :timestamp]
  end

  defmodule TestCommand do
    use PropertyDamage.Command, observables: [TestEvent]
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:value, :item_ref]

    @impl true
    def generator(overrides \\ %{}) do
      %{value: StreamData.integer(1..100)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule ReferenceAdapter do
    @moduledoc "Reference adapter that returns predictable results"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx, _runtime) do
      item_ref = "item_#{ctx.counter}"
      {:ok, [%TestEvent{value: value, item_ref: item_ref, id: 1, timestamp: 1000}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  defmodule IdenticalAdapter do
    @moduledoc "Adapter that returns identical results to reference"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx, _runtime) do
      item_ref = "item_#{ctx.counter}"
      {:ok, [%TestEvent{value: value, item_ref: item_ref, id: 1, timestamp: 1000}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  defmodule DivergentAdapter do
    @moduledoc "Adapter that returns different results"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx, _runtime) do
      item_ref = "item_#{ctx.counter}"
      # Returns different value
      {:ok, [%TestEvent{value: value + 100, item_ref: item_ref, id: 2, timestamp: 2000}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  defmodule SlowAdapter do
    @moduledoc "Adapter with artificial delay for timing tests"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{delay_ms: 10, counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx, _runtime) do
      Process.sleep(ctx.delay_ms)
      item_ref = "item_#{ctx.counter}"
      {:ok, [%TestEvent{value: value, item_ref: item_ref, id: 1, timestamp: 1000}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  defmodule ErrorAdapter do
    @moduledoc "Adapter that returns errors"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, _ctx, _runtime), do: {:error, :simulated_error}
  end

  # Characterization support (F2 sink-window refactor): an adapter that injects
  # one event mid-execution and then returns another. The framework must fold the
  # injected event into the target's result AHEAD of the returned event
  # (injected ++ returned), so divergence sees one uniform stream.
  defmodule InjectingCandidateAdapter do
    @moduledoc "Injects a fixed event during execute, then returns a value event."
    use PropertyDamage.Adapter

    @injected %TestEvent{value: -1, item_ref: "injected", id: :inj, timestamp: 0}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, _ctx, runtime) do
      runtime.inject.(@injected)
      {:ok, [%TestEvent{value: value, item_ref: "returned", id: :ret, timestamp: 0}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  defmodule PreCombinedAdapter do
    @moduledoc "Returns [injected, returned] directly (no inject); the reference."
    use PropertyDamage.Adapter

    @injected %TestEvent{value: -1, item_ref: "injected", id: :inj, timestamp: 0}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, _ctx, _runtime) do
      {:ok, [@injected, %TestEvent{value: value, item_ref: "returned", id: :ret, timestamp: 0}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  defmodule ReturnedOnlyAdapter do
    @moduledoc "Returns only the returned event (no injected); negative control."
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, _ctx, _runtime) do
      {:ok, [%TestEvent{value: value, item_ref: "returned", id: :ret, timestamp: 0}]}
    end

    def execute(_cmd, _ctx, _runtime), do: {:ok, []}
  end

  # ============================================================================
  # Test Support - Model
  # ============================================================================

  defmodule TestProjection do
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{items: %{}, counter: 0}

    @impl true
    def apply(state, %TestCommand{}) do
      %{state | counter: state.counter + 1}
    end

    def apply(state, %TestEvent{item_ref: ref, value: val}) do
      put_in(state, [:items, ref], val)
    end

    def apply(state, _), do: state
  end

  defmodule TestObservation do
    # The values each target folded, in fold order: what the targets are
    # compared on at every root boundary.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{folded: []}

    @impl true
    def apply(state, %TestEvent{item_ref: ref, value: val}),
      do: %{state | folded: [{ref, val} | state.folded]}

    def apply(state, _), do: state

    @compare every: 1
    def folded(state, _root), do: Enum.reverse(state.folded)
  end

  defmodule TimingObservation do
    # Latency tests compare nothing a target's speed or errors change: one
    # observation at the end that every target agrees on.
    use PropertyDamage.Model.Projection

    @compare every: :end
    def finished(_state, _root), do: :finished
  end

  defmodule LatencyModel do
    @behaviour PropertyDamage.Model

    @impl PropertyDamage.Model
    def commands, do: [TestCommand]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: TestProjection

    @impl PropertyDamage.Model
    def check_projections, do: [TimingObservation]
  end

  defmodule TestChecks do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: 1
    def assert_always_pass(_state, _cmd_or_event), do: :ok
  end

  defmodule TestModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl PropertyDamage.Model
    def commands, do: [TestCommand]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: TestProjection

    @impl PropertyDamage.Model
    def check_projections, do: [TestChecks, TestObservation]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%TestCommand{value: value}, _state) do
      [%TestEvent{value: value, item_ref: nil, id: nil, timestamp: nil}]
    end
  end

  # ============================================================================
  # run/1 with several targets
  # ============================================================================

  defp run_targets(opts), do: PropertyDamage.run(Keyword.put_new(opts, :validate, false))

  describe "run/1 validation" do
    test "requires model option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :model option not found/, fn ->
        run_targets(targets: [ReferenceAdapter])
      end
    end

    test "requires targets option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :targets option not found/, fn ->
        run_targets(model: TestModel)
      end
    end

    test "two targets are compared without any compare: option" do
      assert {:error, %FailureReport{kind: :diverged}} =
               run_targets(
                 model: TestModel,
                 targets: [ReferenceAdapter, {DivergentAdapter, name: "divergent"}],
                 max_runs: 1,
                 max_commands: 2,
                 seed: 12_345,
                 shrink: false
               )
    end

    test "validates the compare: option" do
      assert_raise NimbleOptions.ValidationError, ~r/compare/, fn ->
        run_targets(
          model: TestModel,
          targets: [ReferenceAdapter],
          compare: :invalid
        )
      end
    end

    test "rejects empty targets" do
      assert_raise NimbleOptions.ValidationError, ~r/expected a non-empty list/, fn ->
        run_targets(model: TestModel, targets: [])
      end
    end
  end

  # ============================================================================
  # Correctness Mode Tests
  # ============================================================================

  describe "run/1 with correctness mode" do
    test "passes when targets produce same results" do
      assert {:ok, stats} =
               run_targets(
                 model: TestModel,
                 targets: [
                   ReferenceAdapter,
                   {IdenticalAdapter, name: "identical"}
                 ],
                 max_runs: 5,
                 max_commands: 3,
                 seed: 12_345
               )

      assert stats.runs == 5
      assert Enum.map(stats.targets, & &1.name) == ["ReferenceAdapter", "identical"]
    end

    test "detects divergence when targets produce different results" do
      assert {:error, %FailureReport{kind: :diverged} = report} =
               run_targets(
                 model: TestModel,
                 targets: [
                   ReferenceAdapter,
                   {DivergentAdapter, name: "divergent"}
                 ],
                 compare: [converge_within: 20],
                 max_runs: 5,
                 max_commands: 3,
                 seed: 12_345
               )

      assert report.variant == %{index: 1, name: "divergent"}
    end
  end

  # ============================================================================
  # Latency measurement
  # ============================================================================

  describe "run/1 with latency: true" do
    test "collects latency metrics" do
      {:ok, stats} =
        run_targets(
          model: TestModel,
          targets: [
            {ReferenceAdapter, name: "fast"},
            {SlowAdapter, name: "slow", config: %{delay_ms: 5}}
          ],
          latency: true,
          max_runs: 3,
          max_commands: 2,
          seed: 12_345
        )

      assert Map.has_key?(stats.metrics, "fast")
      assert Map.has_key?(stats.metrics, "slow")

      fast_metrics = stats.metrics["fast"]
      assert Map.has_key?(fast_metrics, :p50)
      assert Map.has_key?(fast_metrics, :p95)
      assert Map.has_key?(fast_metrics, :p99)
    end

    test "slow adapter has higher latency" do
      {:ok, stats} =
        run_targets(
          model: TestModel,
          targets: [
            {ReferenceAdapter, name: "fast"},
            {SlowAdapter, name: "slow", config: %{delay_ms: 10}}
          ],
          latency: true,
          max_runs: 3,
          max_commands: 3,
          seed: 12_345
        )

      fast_p50 = stats.metrics["fast"].p50
      slow_p50 = stats.metrics["slow"].p50

      # Slow adapter should have higher latency
      assert slow_p50 > fast_p50
    end

    test "an erroring target ends the run as its execution failure instead of being counted" do
      {:error, report} =
        run_targets(
          model: LatencyModel,
          targets: [
            {ReferenceAdapter, name: "working"},
            {ErrorAdapter, name: "broken"}
          ],
          latency: true,
          max_runs: 2,
          max_commands: 2,
          seed: 12_345,
          shrink: false
        )

      assert report.kind == :execution_failed
      assert report.variant == %{index: 1, name: "broken"}
      assert Failure.kind(report.failure_reason) == :adapter_error
      assert Failure.detail(report.failure_reason) == :simulated_error
    end

    test "reports exactly the timing keys for targets that answer every command" do
      {:ok, stats} =
        run_targets(
          model: LatencyModel,
          targets: [
            {ReferenceAdapter, name: "working"},
            {SlowAdapter, name: "slow", config: %{delay_ms: 1}}
          ],
          latency: true,
          max_runs: 2,
          max_commands: 2,
          seed: 12_345
        )

      for name <- ["working", "slow"] do
        assert stats.metrics[name] |> Map.keys() |> Enum.sort() ==
                 [:by_command, :commands, :max, :mean, :min, :p50, :p95, :p99]
      end
    end
  end

  # ============================================================================
  # Same Adapter Different Config Tests
  # ============================================================================

  describe "same adapter with different configs" do
    test "can compare same adapter with different configs" do
      {:ok, stats} =
        run_targets(
          model: TestModel,
          targets: [
            {SlowAdapter, name: "fast-config", config: %{delay_ms: 1}},
            {SlowAdapter, name: "slow-config", config: %{delay_ms: 20}}
          ],
          latency: true,
          max_runs: 2,
          max_commands: 2,
          seed: 12_345
        )

      assert Enum.map(stats.targets, & &1.name) == ["fast-config", "slow-config"]

      # Verify different configs were used
      fast_latency = stats.metrics["fast-config"].p50
      slow_latency = stats.metrics["slow-config"].p50

      assert slow_latency > fast_latency
    end
  end

  # ============================================================================
  # Concurrency
  # ============================================================================

  describe "concurrency" do
    test "serial is the default and a report records the run's concurrency" do
      assert {:error, serial} =
               run_targets(
                 model: TestModel,
                 targets: [ReferenceAdapter, DivergentAdapter],
                 compare: [converge_within: 20],
                 max_runs: 2,
                 max_commands: 2,
                 seed: 12_345
               )

      assert serial.concurrency == :serial

      assert {:error, parallel} =
               run_targets(
                 model: TestModel,
                 targets: [ReferenceAdapter, DivergentAdapter],
                 concurrency: :parallel,
                 compare: [converge_within: 20],
                 max_runs: 2,
                 max_commands: 2,
                 seed: 12_345
               )

      assert parallel.concurrency == :parallel
    end
  end

  describe "retired options" do
    for key <- [:baseline, :export_to] do
      test "#{key}: is rejected as an unknown option" do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            run_targets([
              {unquote(key), "x.json"},
              model: TestModel,
              targets: [ReferenceAdapter, IdenticalAdapter],
              max_runs: 1,
              max_commands: 2,
              seed: 12_345
            ])
          end

        assert error.message =~ inspect(unquote(key))
      end
    end
  end

  # ============================================================================
  # Progress projection (DR-022)
  # ============================================================================

  describe "run/1 progress (DR-022)" do
    test "on_progress receives :run updates then a terminal result" do
      test_pid = self()

      {:ok, stats} =
        run_targets(
          model: TestModel,
          targets: [
            ReferenceAdapter,
            {IdenticalAdapter, name: "identical"}
          ],
          max_runs: 3,
          max_commands: 2,
          seed: 12_345,
          on_progress: fn progress -> send(test_pid, {:progress, progress}) end
        )

      progresses = drain_progress([])

      run_updates =
        Enum.filter(progresses, &match?(%Progress{data: %RunUpdate{phase: :run}}, &1))

      assert length(run_updates) == 3

      assert %Progress{data: %RunUpdate{phase: :run, run_number: 1, total_runs: 3}} =
               hd(run_updates)

      assert %Progress{data: %RunResult{outcome: :ok, runs_completed: runs}} =
               List.last(progresses)

      assert runs == stats.runs
    end

    test "emits the test_run progress and result telemetry events" do
      parent = self()
      handler_id = "pd-targets-progress-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:property_damage, :test_run, :progress],
          [:property_damage, :test_run, :result]
        ],
        &__MODULE__.forward_telemetry/4,
        parent
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      run_targets(
        model: TestModel,
        targets: [
          ReferenceAdapter,
          {IdenticalAdapter, name: "identical"}
        ],
        max_runs: 2,
        max_commands: 2,
        seed: 12_345
      )

      assert_received {:telemetry, [:property_damage, :test_run, :progress], _m,
                       %{data: %RunUpdate{}}}

      assert_received {:telemetry, [:property_damage, :test_run, :result], _m,
                       %{data: %RunResult{}}}
    end
  end

  # ============================================================================
  # Characterization: per-target injected-event capture
  #
  # An adapter that injects mid-execution has the injected event folded AHEAD
  # of its returned events (injected, then returned), as TestObservation's
  # fold-order list shows. If that folding drops, reorders, or double-counts
  # injected events, the positive test flips to divergent; the negative control
  # proves the tests actually observe the injected event.
  # ============================================================================
  describe "injected-event folding (characterization)" do
    test "an injected event is folded ahead of returned events" do
      # The injecting target folds [injected, returned], matching the reference
      # that returns that stream directly: no divergence.
      assert {:ok, _stats} =
               run_targets(
                 model: TestModel,
                 targets: [
                   PreCombinedAdapter,
                   {InjectingCandidateAdapter, name: "injecting"}
                 ],
                 max_runs: 3,
                 max_commands: 3,
                 seed: 12_345
               )
    end

    test "the injected event is actually observed (negative control)" do
      # Reference emits only the returned event; the injecting target additionally
      # folds the injected event, so the observations diverge. This proves the
      # positive test above is not passing by silently dropping injected events.
      assert {:error, %FailureReport{kind: :diverged}} =
               run_targets(
                 model: TestModel,
                 targets: [
                   ReturnedOnlyAdapter,
                   {InjectingCandidateAdapter, name: "injecting"}
                 ],
                 compare: [converge_within: 20],
                 max_runs: 3,
                 max_commands: 3,
                 seed: 12_345
               )
    end
  end

  defp drain_progress(acc) do
    receive do
      {:progress, progress} -> drain_progress([progress | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
