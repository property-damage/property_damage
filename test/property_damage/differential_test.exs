defmodule PropertyDamage.DifferentialTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Differential
  alias PropertyDamage.Differential.{Target, Result, Equivalence, Baseline}

  # ============================================================================
  # Test Support - Adapters
  # ============================================================================

  defmodule TestEvent do
    defstruct [:value, :item_ref, :id, :timestamp]
  end

  defmodule TestCommand do
    @behaviour PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:value, :item_ref]

    @impl true
    def creates_ref, do: :item_ref

    @impl true
    def downstream_observables, do: [TestEvent]

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
    def execute(%TestCommand{value: value}, ctx) do
      item_ref = "item_#{ctx.counter}"
      {:ok, [%TestEvent{value: value, item_ref: item_ref, id: 1, timestamp: 1000}]}
    end

    def execute(_cmd, _ctx), do: {:ok, []}
  end

  defmodule IdenticalAdapter do
    @moduledoc "Adapter that returns identical results to reference"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx) do
      item_ref = "item_#{ctx.counter}"
      {:ok, [%TestEvent{value: value, item_ref: item_ref, id: 1, timestamp: 1000}]}
    end

    def execute(_cmd, _ctx), do: {:ok, []}
  end

  defmodule DivergentAdapter do
    @moduledoc "Adapter that returns different results"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx) do
      item_ref = "item_#{ctx.counter}"
      # Returns different value
      {:ok, [%TestEvent{value: value + 100, item_ref: item_ref, id: 2, timestamp: 2000}]}
    end

    def execute(_cmd, _ctx), do: {:ok, []}
  end

  defmodule SlowAdapter do
    @moduledoc "Adapter with artificial delay for timing tests"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.merge(%{delay_ms: 10, counter: 0}, config)}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%TestCommand{value: value}, ctx) do
      Process.sleep(ctx.delay_ms)
      item_ref = "item_#{ctx.counter}"
      {:ok, [%TestEvent{value: value, item_ref: item_ref, id: 1, timestamp: 1000}]}
    end

    def execute(_cmd, _ctx), do: {:ok, []}
  end

  defmodule ErrorAdapter do
    @moduledoc "Adapter that returns errors"
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_cmd, _ctx), do: {:error, :simulated_error}
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

  defmodule TestAssertions do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @trigger every: 1
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
    def assertion_projections, do: [TestAssertions]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%TestCommand{value: value}, _state) do
      [%TestEvent{value: value, item_ref: nil, id: nil, timestamp: nil}]
    end
  end

  # ============================================================================
  # Target Parsing Tests
  # ============================================================================

  describe "Target.parse/2" do
    test "parses minimal target spec" do
      target = Target.parse({ReferenceAdapter}, 0)

      assert target.adapter == ReferenceAdapter
      assert target.name == "reference_0"
      assert target.role == :candidate
      assert target.opts == %{}
    end

    test "parses target with name" do
      target = Target.parse({ReferenceAdapter, name: "my-adapter"}, 0)

      assert target.name == "my-adapter"
    end

    test "parses target with role" do
      target = Target.parse({ReferenceAdapter, role: :reference}, 0)

      assert target.role == :reference
    end

    test "parses target with opts" do
      target = Target.parse({ReferenceAdapter, opts: [url: "http://test"]}, 0)

      assert target.opts == %{url: "http://test"}
    end

    test "parses full specification" do
      target =
        Target.parse(
          {ReferenceAdapter, name: "prod", role: :reference, opts: [pool_size: 10]},
          0
        )

      assert target.adapter == ReferenceAdapter
      assert target.name == "prod"
      assert target.role == :reference
      assert target.opts == %{pool_size: 10}
    end
  end

  # ============================================================================
  # Equivalence Tests
  # ============================================================================

  describe "Equivalence.equivalent?/3" do
    test "exact equivalence requires identical results" do
      result = {:ok, [%TestEvent{value: 1, id: 1}]}

      assert Equivalence.equivalent?(result, result, :exact)
      refute Equivalence.equivalent?(result, {:ok, [%TestEvent{value: 2, id: 1}]}, :exact)
    end

    test "structural equivalence ignores id and timestamp" do
      ref = {:ok, [%TestEvent{value: 1, item_ref: "a", id: 1, timestamp: 1000}]}
      sut = {:ok, [%TestEvent{value: 1, item_ref: "a", id: 999, timestamp: 9999}]}

      assert Equivalence.equivalent?(ref, sut, :structural)
    end

    test "structural equivalence detects value differences" do
      ref = {:ok, [%TestEvent{value: 1, item_ref: "a", id: 1}]}
      sut = {:ok, [%TestEvent{value: 2, item_ref: "a", id: 1}]}

      refute Equivalence.equivalent?(ref, sut, :structural)
    end

    test "custom equivalence function" do
      custom = fn {:ok, [%{value: v1}]}, {:ok, [%{value: v2}]} ->
        abs(v1 - v2) < 10
      end

      ref = {:ok, [%TestEvent{value: 100}]}
      close = {:ok, [%TestEvent{value: 105}]}
      far = {:ok, [%TestEvent{value: 200}]}

      assert Equivalence.equivalent?(ref, close, custom)
      refute Equivalence.equivalent?(ref, far, custom)
    end

    test "error results compared correctly" do
      assert Equivalence.equivalent?({:error, :timeout}, {:error, :timeout}, :exact)
      refute Equivalence.equivalent?({:error, :timeout}, {:error, :other}, :exact)
    end
  end

  describe "Equivalence.ignore_fields/1" do
    test "creates strategy ignoring specific fields" do
      strategy = Equivalence.ignore_fields([:request_id, :correlation_id])

      ref = {:ok, [%{value: 1, request_id: "abc", correlation_id: "xyz"}]}
      sut = {:ok, [%{value: 1, request_id: "def", correlation_id: "uvw"}]}

      assert Equivalence.equivalent?(ref, sut, strategy)
    end
  end

  describe "Equivalence.only_fields/1" do
    test "creates strategy comparing only specific fields" do
      strategy = Equivalence.only_fields([:value, :item_ref])

      ref = {:ok, [%TestEvent{value: 1, item_ref: "a", id: 1, timestamp: 1000}]}
      sut = {:ok, [%TestEvent{value: 1, item_ref: "a", id: 999, timestamp: 9999}]}

      assert Equivalence.equivalent?(ref, sut, strategy)
    end
  end

  # ============================================================================
  # Differential.run/1 Validation Tests
  # ============================================================================

  describe "run/1 validation" do
    test "requires model option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :model option not found/, fn ->
        Differential.run(targets: [{ReferenceAdapter}], compare: :correctness)
      end
    end

    test "requires targets option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :targets option not found/, fn ->
        Differential.run(model: TestModel, compare: :correctness)
      end
    end

    test "requires compare option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :compare option not found/, fn ->
        Differential.run(model: TestModel, targets: [{ReferenceAdapter}])
      end
    end

    test "validates compare mode" do
      assert_raise NimbleOptions.ValidationError, ~r/:compare.*expected one of/, fn ->
        Differential.run(
          model: TestModel,
          targets: [{ReferenceAdapter}],
          compare: :invalid
        )
      end
    end

    test "rejects empty targets" do
      assert_raise NimbleOptions.ValidationError, ~r/expected a non-empty list/, fn ->
        Differential.run(model: TestModel, targets: [], compare: :correctness)
      end
    end

    test "rejects multiple references" do
      assert {:error, {:invalid_targets, _}} =
               Differential.run(
                 model: TestModel,
                 targets: [
                   {ReferenceAdapter, role: :reference},
                   {IdenticalAdapter, role: :reference}
                 ],
                 compare: :correctness
               )
    end
  end

  # ============================================================================
  # Correctness Mode Tests
  # ============================================================================

  describe "run/1 with correctness mode" do
    test "returns equivalent when targets produce same results" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, role: :reference},
            {IdenticalAdapter, name: "identical"}
          ],
          compare: :correctness,
          max_runs: 5,
          max_commands: 3,
          seed: 12345
        )

      assert result.mode == :correctness
      assert result.status == :equivalent
      assert result.divergences == []
      assert "reference_0" in result.targets
      assert "identical" in result.targets
    end

    test "detects divergence when targets produce different results" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, role: :reference},
            {DivergentAdapter, name: "divergent"}
          ],
          compare: :correctness,
          max_runs: 5,
          max_commands: 3,
          seed: 12345
        )

      assert result.status == :divergent
      assert length(result.divergences) > 0

      [div | _] = result.divergences
      assert div.divergent_target == "divergent"
    end

    test "uses structural equivalence when specified" do
      # DivergentAdapter changes id and timestamp but structural ignores those
      # Actually DivergentAdapter changes the value too, so let's use a different test

      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, role: :reference},
            {IdenticalAdapter, name: "identical"}
          ],
          compare: :correctness,
          equivalence: :structural,
          max_runs: 3,
          max_commands: 2,
          seed: 12345
        )

      assert result.status == :equivalent
    end
  end

  # ============================================================================
  # Performance Mode Tests
  # ============================================================================

  describe "run/1 with performance mode" do
    test "collects latency metrics" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, name: "fast"},
            {SlowAdapter, name: "slow", opts: %{delay_ms: 5}}
          ],
          compare: :performance,
          max_runs: 3,
          max_commands: 2,
          seed: 12345
        )

      assert result.mode == :performance
      assert Map.has_key?(result.metrics, "fast")
      assert Map.has_key?(result.metrics, "slow")

      fast_metrics = result.metrics["fast"]
      assert Map.has_key?(fast_metrics, :latency_p50)
      assert Map.has_key?(fast_metrics, :latency_p95)
      assert Map.has_key?(fast_metrics, :latency_p99)
    end

    test "slow adapter has higher latency" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, name: "fast"},
            {SlowAdapter, name: "slow", opts: %{delay_ms: 10}}
          ],
          compare: :performance,
          max_runs: 3,
          max_commands: 3,
          seed: 12345
        )

      fast_p50 = result.metrics["fast"].latency_p50
      slow_p50 = result.metrics["slow"].latency_p50

      # Slow adapter should have higher latency
      assert slow_p50 > fast_p50
    end

    test "counts errors correctly" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, name: "working"},
            {ErrorAdapter, name: "broken"}
          ],
          compare: :performance,
          max_runs: 2,
          max_commands: 2,
          seed: 12345
        )

      working_metrics = result.metrics["working"]
      broken_metrics = result.metrics["broken"]

      assert working_metrics.error_count == 0
      assert broken_metrics.error_count > 0
    end
  end

  # ============================================================================
  # Result Tests
  # ============================================================================

  describe "Result" do
    test "equivalent?/1 returns true for equivalent status" do
      result = %Result{status: :equivalent, divergences: [], metrics: %{}, targets: []}
      assert Result.equivalent?(result)
    end

    test "divergent?/1 returns true for divergent status" do
      result = %Result{status: :divergent, divergences: [%{}], metrics: %{}, targets: []}
      assert Result.divergent?(result)
    end

    test "divergence_count/1 returns correct count" do
      result = %Result{divergences: [%{}, %{}, %{}], metrics: %{}, targets: []}
      assert Result.divergence_count(result) == 3
    end

    test "format/1 produces readable output" do
      result = %Result{
        mode: :correctness,
        execution: :interleaved,
        runs: 100,
        seed: 12345,
        reference: "oracle",
        status: :equivalent,
        divergences: [],
        metrics: %{},
        targets: ["oracle", "sut"]
      }

      output = Result.format(result)
      assert output =~ "Differential Testing Result"
      assert output =~ "correctness"
      assert output =~ "EQUIVALENT"
    end
  end

  # ============================================================================
  # Baseline Tests
  # ============================================================================

  describe "Baseline" do
    @tag :tmp_dir
    test "exports and loads baseline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_baseline.json")

      # Create mock run data
      run_data = %{
        runs: [
          %{
            commands: [%TestCommand{value: 1}],
            results: [{:ok, [%TestEvent{value: 1, item_ref: "a"}]}],
            timings: [100, 200],
            event_log: [%TestEvent{value: 1}],
            is_warmup: false
          }
        ],
        setup_success: true
      }

      config = %{
        model: TestModel,
        targets: [{ReferenceAdapter, name: "test"}],
        seed: 12345
      }

      # Export
      :ok = Baseline.export_run_data(run_data, config, path)
      assert File.exists?(path)

      # Load
      {:ok, baseline} = Baseline.load(path)

      assert baseline.seed == 12345
      assert length(baseline.runs) == 1
    end

    test "load returns error for missing file" do
      assert {:error, {:file_not_found, _}} = Baseline.load("/nonexistent/path.json")
    end
  end

  # ============================================================================
  # Same Adapter Different Config Tests
  # ============================================================================

  describe "same adapter with different configs" do
    test "can compare same adapter with different opts" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {SlowAdapter, name: "fast-config", opts: %{delay_ms: 1}},
            {SlowAdapter, name: "slow-config", opts: %{delay_ms: 20}}
          ],
          compare: :performance,
          max_runs: 2,
          max_commands: 2,
          seed: 12345
        )

      assert "fast-config" in result.targets
      assert "slow-config" in result.targets

      # Verify different configs were used
      fast_latency = result.metrics["fast-config"].latency_p50
      slow_latency = result.metrics["slow-config"].latency_p50

      assert slow_latency > fast_latency
    end
  end

  # ============================================================================
  # Execution Mode Tests
  # ============================================================================

  describe "execution modes" do
    test "interleaved is default for correctness" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, role: :reference},
            {IdenticalAdapter}
          ],
          compare: :correctness,
          max_runs: 2,
          max_commands: 2,
          seed: 12345
        )

      assert result.execution == :interleaved
    end

    test "sequential is default for performance" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter},
            {IdenticalAdapter}
          ],
          compare: :performance,
          max_runs: 2,
          max_commands: 2,
          seed: 12345
        )

      assert result.execution == :sequential
    end

    test "can override execution mode" do
      {:ok, result} =
        Differential.run(
          model: TestModel,
          targets: [
            {ReferenceAdapter, role: :reference},
            {IdenticalAdapter}
          ],
          compare: :correctness,
          execution: :sequential,
          max_runs: 2,
          max_commands: 2,
          seed: 12345
        )

      assert result.execution == :sequential
    end
  end
end
