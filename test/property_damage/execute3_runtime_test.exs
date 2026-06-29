defmodule PropertyDamage.Execute3RuntimeTest do
  @moduledoc """
  Regression tests for the execute/2 -> execute/3 cutover (DR-027).

  These pin the load-bearing behavior deltas:

    * `execute/3` receives the adapter's `setup/1` return *exactly* as
      `user_context` (no framework keys merged in), and
    * mid-execution `inject` works from the load-test worker's spawned Task
      (the old process-dictionary channel did not cross that boundary and
      raised "inject called outside adapter execution context").
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.{Executor, Sequence}
  alias PropertyDamage.LoadTest.{Metrics, Worker}

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
    @behaviour PropertyDamage.Model.Simulator
    @impl PropertyDamage.Model
    def commands, do: [Cmd]
    @impl PropertyDamage.Model
    def command_sequence_projection, do: Proj
    @impl PropertyDamage.Model
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_cmd, _state), do: [%{type: :created}]
    @impl PropertyDamage.Model
    def assertion_projections, do: []
  end

  describe "user_context is exactly the setup/1 return (no framework keys)" do
    defmodule PurityAdapter do
      use PropertyDamage.Adapter

      @impl true
      def setup(config), do: {:ok, %{marker: :only_mine, test_pid: config.test_pid}}

      @impl true
      def teardown(_user_context), do: :ok

      @impl true
      def execute(_cmd, user_context, runtime) do
        send(user_context.test_pid, {:user_context, user_context})
        send(user_context.test_pid, {:runtime, runtime})
        {:ok, [%Ev{type: :done}]}
      end
    end

    test "arg 2 carries no :inject/:start_poller/:stutter; affordances live on the runtime" do
      seq = Sequence.linear([%Cmd{value: 1}])

      {:ok, _result} =
        Executor.run(seq, Model, PurityAdapter, adapter_config: %{test_pid: self()})

      assert_received {:user_context, user_context}
      assert user_context == %{marker: :only_mine, test_pid: self()}
      refute Map.has_key?(user_context, :inject)
      refute Map.has_key?(user_context, :start_poller)
      refute Map.has_key?(user_context, :stutter)

      assert_received {:runtime, runtime}
      assert %PropertyDamage.Runtime{} = runtime
      assert is_function(runtime.inject, 1)
      assert is_function(runtime.start_poller, 1)
      refute PropertyDamage.Runtime.stuttering?(runtime)
    end
  end

  describe "load-test worker inject crosses the spawned Task boundary" do
    defmodule WorkerInjectAdapter do
      use PropertyDamage.Adapter, default_timeout: 30

      @impl true
      def setup(_config), do: {:ok, %{}}

      @impl true
      def teardown(_user_context), do: :ok

      @impl true
      def execute(_cmd, _user_context, runtime) do
        # Runs inside the worker's timeout Task. The sink is referenced by pid,
        # so this inject accumulates instead of raising (the bug DR-027 fixes).
        runtime.inject.(%{type: :injected})
        {:ok, [%{type: :returned}]}
      end
    end

    test "an injecting adapter executes without crashing the worker" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: Model,
          adapter: WorkerInjectAdapter,
          adapter_config: %{},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      assert {:ok, _stats} = Worker.execute_sequence(worker)

      Worker.stop(worker)
      Metrics.stop(metrics)
    end
  end
end
