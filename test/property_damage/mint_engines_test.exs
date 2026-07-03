defmodule PropertyDamage.MintEnginesTest do
  @moduledoc """
  DR-034: the Differential and LoadTest resolution engines thread a real run
  nonce, so `mint_per_run` values are per-run unique (Differential: byte-identical
  across targets; LoadTest: distinct per worker).
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.{Differential, Mint}
  alias PropertyDamage.LoadTest.{Metrics, Worker, WorkerPool}

  defmodule Send do
    @behaviour PropertyDamage.Command
    defstruct [:request_id]
    @impl true
    def generator(_), do: StreamData.constant(%{request_id: PropertyDamage.mint_per_run(:uuid)})
  end

  defmodule Proj do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{}
    @impl true
    def apply(state, _), do: state
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands, do: [Send]
    @impl true
    def command_sequence_projection, do: Proj
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(_c, _s), do: []
  end

  # Two differential targets that report the request id they received.
  defmodule TargetA do
    use PropertyDamage.Adapter
    @impl true
    def setup(c), do: {:ok, Map.put(c, :tag, :a)}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def execute(%Send{request_id: rid}, %{test_pid: pid, tag: tag}, _rt) do
      send(pid, {:got, tag, rid})
      {:ok, []}
    end
  end

  defmodule TargetB do
    use PropertyDamage.Adapter
    @impl true
    def setup(c), do: {:ok, Map.put(c, :tag, :b)}
    @impl true
    def teardown(_), do: :ok
    @impl true
    def execute(%Send{request_id: rid}, %{test_pid: pid, tag: tag}, _rt) do
      send(pid, {:got, tag, rid})
      {:ok, []}
    end
  end

  defp expected(nonce, epoch) do
    Mint.reify(Mint.new(:uuid), Position.prefix(0), [:request_id])
    |> Mint.resolve(nonce, epoch)
  end

  describe "Differential threads a shared run nonce" do
    test "all targets receive byte-identical minted requests derived from the nonce" do
      {:ok, _result} =
        Differential.run(
          model: Model,
          targets: [{TargetA, name: "a"}, {TargetB, name: "b"}],
          compare: :correctness,
          adapter_config: %{test_pid: self()},
          run_nonce: 7,
          seed: 12_345,
          max_runs: 1,
          max_commands: 1
        )

      assert_receive {:got, :a, a_rid}
      assert_receive {:got, :b, b_rid}

      # Byte-identical across targets (correct like-for-like), and derived from
      # the run's nonce (epoch 0) — not the old default nil nonce.
      assert a_rid == b_rid
      assert a_rid == expected(7, 0)
      refute a_rid == expected(nil, 0)
    end
  end

  describe "LoadTest threads a run nonce to workers" do
    test "the worker pool forwards the run nonce into each worker" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, pool} =
        WorkerPool.start_link(
          model: Model,
          adapter: TargetA,
          adapter_config: %{test_pid: self()},
          metrics: metrics,
          run_nonce: 42
        )

      {:ok, worker} = WorkerPool.checkout(pool)
      assert :sys.get_state(worker).run_nonce == 42
    end

    test "a worker mints concrete values from its (nonce, worker_id) epoch" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 3,
          model: Model,
          adapter: TargetA,
          adapter_config: %{test_pid: self()},
          metrics: metrics,
          run_nonce: 99
        )

      Worker.execute_sequence(worker)

      # The SUT received a concrete UUID (resolved), never a leftover marker or
      # the nil-nonce default, derived at the worker's epoch (its worker_id).
      assert_receive {:got, :a, rid}
      assert is_binary(rid)
      assert rid == expected(99, 3)
      refute rid == expected(nil, 0)
    end
  end
end
