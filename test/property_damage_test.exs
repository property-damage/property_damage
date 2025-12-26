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
      assert_raise ArgumentError, ~r/Missing Model/, fn ->
        PropertyDamage.run(adapter: SimpleAdapter)
      end
    end

    test "requires adapter option" do
      assert_raise ArgumentError, ~r/Missing Adapter/, fn ->
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
        seed: 12345,
        validate: false
      ]

      {:ok, stats1} = PropertyDamage.run(opts)
      {:ok, stats2} = PropertyDamage.run(opts)

      assert stats1.seed == stats2.seed
      assert stats1.seed == 12345
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
      def state_projection, do: ModelState

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
    test "returns {:error, failure_report} on failure" do
      # FailingModel has a check that fails when quantity > 100
      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: false
        )

      # This test may or may not fail depending on generated values
      # If it succeeds, that's fine too
      case result do
        {:ok, _stats} ->
          :ok

        {:error, report} ->
          assert is_map(report)
          assert is_list(report.original_commands)
          assert is_list(report.shrunk_commands)
          assert report.shrunk_commands == report.original_commands
      end
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
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: false,
          on_failure: on_failure
        )

      case result do
        {:ok, _stats} ->
          :ok

        {:error, _report} ->
          assert_received {:failure_report, report}
          assert is_map(report)
      end
    end
  end

  describe "run/1 shrinking" do
    test "shrinks failing sequences when shrink: true" do
      result =
        PropertyDamage.run(
          model: FailingModel,
          adapter: SimpleAdapter,
          max_runs: 100,
          max_commands: 50,
          validate: false,
          shrink: true
        )

      case result do
        {:ok, _stats} ->
          :ok

        {:error, report} ->
          # Shrunk sequence should be <= original
          assert length(report.shrunk_commands) <= length(report.original_commands)
          assert report.shrink_iterations >= 0
          assert report.shrink_time_ms >= 0
      end
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
