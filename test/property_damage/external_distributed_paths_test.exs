defmodule PropertyDamage.ExternalDistributedPathsTest do
  @moduledoc """
  external() capture across the distributed execution paths (DR-021).

  `PropertyDamage.run/1` and `execute/2` already captured server-generated
  values produced by one command and resolved them into later ones. These tests
  cover the two paths that previously did NOT: `Differential.run/1` (which used
  to pass unresolved placeholders straight through) and the `LoadTest.Worker`
  (which used to raise on the first unresolved placeholder). Each now builds a
  per-run placeholder registry, captures real values by the producer's linear
  position, and resolves consumers against it.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Differential, Generator, Placeholder}
  alias PropertyDamage.LoadTest.{Metrics, Worker}

  # --- Shared producer/consumer surface (mirrors external_e2e_test.exs) -------

  defmodule Created do
    import PropertyDamage, only: [external: 0]
    defstruct [:label, id: external()]
  end

  defmodule Create do
    @behaviour PropertyDamage.Command
    defstruct [:label]
    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{label: StreamData.constant("x")}, overrides)
      )
    end
  end

  defmodule Use do
    @behaviour PropertyDamage.Command
    defstruct [:target]
    @impl true
    def generator(overrides) do
      StreamData.fixed_map(
        Generator.merge_overrides(%{target: StreamData.constant(nil)}, overrides)
      )
    end
  end

  defmodule Projection do
    @behaviour PropertyDamage.Model.Projection
    @impl true
    def init, do: %{created: []}
    @impl true
    def apply(state, %Created{id: id}), do: %{state | created: [id | state.created]}
    def apply(state, _other), do: state
  end

  # Create yields a server id whose value is keyed by the per-target `prefix`, so
  # two targets capture distinct concretes for the same consumer placeholder.
  # Use reports the (resolved) target it received so tests can assert it is a
  # concrete value, never a %Placeholder{} / %External{}.
  defmodule ProbingAdapter do
    use PropertyDamage.Adapter, default_timeout: 5

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def execute(%Create{label: label}, ctx, _runtime) do
      prefix = Map.get(ctx, :prefix, "real")
      {:ok, [%Created{label: label, id: "#{prefix}_id"}]}
    end

    def execute(%Use{target: target}, ctx, _runtime) do
      if pid = Map.get(ctx, :test_pid) do
        send(pid, {:used, Map.get(ctx, :name), target})
      end

      {:ok, []}
    end

    @impl true
    def teardown(_ctx), do: :ok
  end

  defmodule RoutingModel do
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator
    @impl true
    def commands do
      [
        Create,
        {Use,
         when: fn state -> state.created != [] end,
         with: fn state -> %{target: Generator.external_from(state, path: [:id])} end}
      ]
    end

    @impl true
    def command_sequence_projection, do: Projection
    @impl true
    def simulator, do: __MODULE__
    @impl PropertyDamage.Model.Simulator
    def simulate(%Create{label: l}, _state), do: [%Created{label: l}]
    def simulate(_command, _state), do: []
  end

  # ---------------------------------------------------------------------------
  # Differential
  # ---------------------------------------------------------------------------

  describe "Differential.run/1 captures external() values" do
    test "interleaved: a consumer receives the concrete value its producer yielded" do
      # Single target => no reference => no divergence halts the sequence, so the
      # whole Create -> Use sequence runs and we can observe resolution.
      used =
        Enum.find_value(1..300, fn seed ->
          drain_used([])

          {:ok, _result} =
            Differential.run(
              model: RoutingModel,
              targets: [{ProbingAdapter, name: "solo", opts: [prefix: "solo", name: "solo"]}],
              compare: :correctness,
              execution: :interleaved,
              max_runs: 1,
              max_commands: 12,
              seed: seed,
              adapter_config: %{test_pid: self()}
            )

          case drain_used([]) do
            [] -> nil
            targets -> targets
          end
        end)

      assert used, "no seed routed a placeholder into a Use command (interleaved)"

      Enum.each(used, fn {_name, target} ->
        refute match?(%Placeholder{}, target)
        refute match?(%PropertyDamage.External{}, target)
        assert target == "solo_id"
      end)
    end

    test "sequential: each target resolves the consumer to its OWN captured value" do
      # Distinct id prefixes per target prove the registries are per-target: the
      # same consumer placeholder resolves to "a_id" under target a and "b_id"
      # under target b. Sequential mode runs each full sequence before comparing,
      # so divergence never truncates a sequence.
      used =
        Enum.find_value(1..300, fn seed ->
          drain_used([])

          {:ok, _result} =
            Differential.run(
              model: RoutingModel,
              targets: [
                {ProbingAdapter, name: "a", opts: [prefix: "a", name: "a"]},
                {ProbingAdapter, name: "b", opts: [prefix: "b", name: "b"]}
              ],
              compare: :correctness,
              execution: :sequential,
              max_runs: 1,
              max_commands: 12,
              seed: seed,
              adapter_config: %{test_pid: self()}
            )

          targets = drain_used([])

          if Enum.any?(targets, &match?({"a", _}, &1)) and
               Enum.any?(targets, &match?({"b", _}, &1)) do
            targets
          end
        end)

      assert used, "no seed routed a Use onto both targets (sequential)"

      for {name, target} <- used do
        refute match?(%Placeholder{}, target)
        assert target == "#{name}_id"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # LoadTest worker
  # ---------------------------------------------------------------------------

  describe "LoadTest.Worker captures external() values" do
    test "routed consumers resolve to concretes instead of raising on a placeholder" do
      {:ok, metrics} = Metrics.start_link()

      {:ok, worker} =
        Worker.start_link(
          worker_id: 1,
          model: RoutingModel,
          adapter: ProbingAdapter,
          adapter_config: %{test_pid: self(), prefix: "w", name: "w"},
          metrics: metrics,
          think_time_range: {0, 0},
          assertion_mode: :disabled
        )

      # The worker generates a fresh sequence per call; run until at least one Use
      # is routed (bounded), so the resolution assertion is non-vacuous. Pre-fix,
      # any routed Use raised an unresolved-placeholder error here.
      used = run_until_routed(worker, 200, [])

      assert used != [], "no generated sequence routed a Use into the worker"

      Enum.each(used, fn {_name, target} ->
        refute match?(%Placeholder{}, target)
        refute match?(%PropertyDamage.External{}, target)
        assert target == "w_id"
      end)

      Process.sleep(50)
      snapshot = Metrics.snapshot(metrics)
      # ProbingAdapter never returns {:error, _}, so the only way to accrue errors
      # is an unresolved placeholder: zero errors is the regression guard.
      assert snapshot.total_errors == 0

      Worker.stop(worker)
      Metrics.stop(metrics)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp run_until_routed(_worker, 0, acc), do: acc

  defp run_until_routed(worker, attempts, acc) do
    {:ok, _stats} = Worker.execute_sequence(worker)
    acc = drain_used(acc)

    if acc != [] do
      acc
    else
      run_until_routed(worker, attempts - 1, acc)
    end
  end

  defp drain_used(acc) do
    receive do
      {:used, name, target} -> drain_used([{name, target} | acc])
    after
      0 -> acc
    end
  end
end
