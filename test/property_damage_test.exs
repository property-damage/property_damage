defmodule PropertyDamageTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.{
    ExecutorModel,
    FailingModel,
    SimpleAdapter
  }

  describe "module" do
    test "defines moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(PropertyDamage)

      assert moduledoc =~ "stateful property-based testing"
    end
  end

  describe "run/1 validation" do
    test "requires model option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :model option not found/, fn ->
        PropertyDamage.run(adapter: SimpleAdapter)
      end
    end

    test "requires adapter option" do
      assert_raise NimbleOptions.ValidationError, ~r/required :adapter option not found/, fn ->
        PropertyDamage.run(model: ExecutorModel)
      end
    end
  end

  describe "run/1 success" do
    test "returns {:ok, stats} on success" do
      result =
        PropertyDamage.run(
          model: ExecutorModel,
          adapter: SimpleAdapter,
          max_runs: 3,
          max_commands: 5,
          validate: false
        )

      assert {:ok, stats} = result
      assert stats.runs == 3
      assert stats.total_commands > 0
      assert is_integer(stats.seed)
    end

    test "respects seed for reproducibility" do
      opts = [
        model: ExecutorModel,
        adapter: SimpleAdapter,
        max_runs: 3,
        max_commands: 5,
        seed: 12_345,
        validate: false
      ]

      {:ok, stats1} = PropertyDamage.run(opts)
      {:ok, stats2} = PropertyDamage.run(opts)

      assert stats1.seed == stats2.seed
      assert stats1.seed == 12_345
    end
  end

  describe "run/1 with lifecycle callbacks" do
    defmodule LifecycleModel do
      @behaviour PropertyDamage.Model

      alias PropertyDamage.Test.Commands.CreateItem
      alias PropertyDamage.Test.Projections.ModelState

      @impl true
      def commands, do: [CreateItem]

      @impl true
      def command_sequence_projection, do: ModelState

      @impl true
      def assertion_projections, do: []

      @impl true
      def setup_once(config) do
        # config is %{adapter_config: %{test_pid: pid}}
        send(config[:adapter_config][:test_pid], :setup_once_called)
        :ok
      end

      @impl true
      def setup_each(config) do
        # config is %{adapter_config: %{test_pid: pid}, run_number: n}
        send(config[:adapter_config][:test_pid], {:setup_each_called, config[:run_number]})
        :ok
      end

      @impl true
      def teardown_each(_config) do
        # Can't reliably send from here due to after block timing
        :ok
      end

      @impl true
      def teardown_once(_config) do
        # Can't reliably send from here due to after block timing
        :ok
      end
    end

    test "calls setup_once at start" do
      PropertyDamage.run(
        model: LifecycleModel,
        adapter: SimpleAdapter,
        max_runs: 1,
        max_commands: 2,
        validate: false,
        adapter_config: %{test_pid: self()}
      )

      assert_received :setup_once_called
    end

    test "calls setup_each before each run" do
      PropertyDamage.run(
        model: LifecycleModel,
        adapter: SimpleAdapter,
        max_runs: 3,
        max_commands: 2,
        validate: false,
        adapter_config: %{test_pid: self()}
      )

      assert_received {:setup_each_called, 0}
      assert_received {:setup_each_called, 1}
      assert_received {:setup_each_called, 2}
    end
  end

  describe "run/1 failure handling" do
    # FailingModel's invariant fails when the CUMULATIVE quantity exceeds
    # 100, so a failure is certain well within these run bounds. The seed is
    # fixed: failure is mandatory, not opportunistic.
    test "returns {:error, failure_report} on failure" do
      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          seed: 42,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: false
        )

      assert {:error, %PropertyDamage.FailureReport{} = report} = result
      assert report.check_name == :quantity_limit
      assert is_integer(report.failed_at_index)

      # With shrink: false the shrunk sequence is the original
      assert report.shrunk_sequence == report.original_sequence
    end

    test "invokes on_failure callback" do
      test_pid = self()

      on_failure = fn report ->
        send(test_pid, {:failure_report, report})
      end

      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          seed: 42,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: false,
          on_failure: on_failure
        )

      assert {:error, _report} = result
      assert_received {:failure_report, report}
      assert %PropertyDamage.FailureReport{check_name: :quantity_limit} = report
    end
  end

  describe "run/1 shrinking" do
    test "shrinks failing sequences when shrink: true" do
      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          seed: 42,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: true
        )

      assert {:error, report} = result

      original = PropertyDamage.Sequence.to_list(report.original_sequence)
      shrunk = PropertyDamage.Sequence.to_list(report.shrunk_sequence)

      assert length(shrunk) <= length(original)

      # Failure equivalence: the shrunk sequence must still violate the
      # invariant (cumulative quantity above the limit)
      shrunk_total = shrunk |> Enum.map(& &1.quantity) |> Enum.sum()
      assert shrunk_total > 100
    end
  end

  describe "run/1 verbose mode" do
    test "prints progress when verbose: true" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PropertyDamage.run(
            model: ExecutorModel,
            adapter: SimpleAdapter,
            max_runs: 2,
            max_commands: 3,
            validate: true,
            verbose: true
          )
        end)

      assert output =~ "PropertyDamage Configuration Summary"
      assert output =~ "Run 1/2"
      assert output =~ "Run 2/2"
    end
  end
end
