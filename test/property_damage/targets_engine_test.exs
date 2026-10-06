defmodule PropertyDamage.TargetsEngineTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.{ExecutorModel, SimpleAdapter}

  # ============================================================================
  # Single-target run: a recording adapter over a working test-support adapter
  # ============================================================================

  defmodule RunRecorder do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      send(config.test_pid, {:run_setup_config, config})
      SimpleAdapter.setup(config)
    end

    @impl true
    def teardown(context), do: SimpleAdapter.teardown(context)

    @impl true
    def execute(command, context, runtime), do: SimpleAdapter.execute(command, context, runtime)
  end

  # ============================================================================
  # Multi-target support: a tiny model plus adapters that differ by module
  # ============================================================================

  defmodule Echoed do
    @moduledoc false
    defstruct [:value, :item_ref, :id, :timestamp]
  end

  defmodule Echo do
    @moduledoc false
    use PropertyDamage.Command, observables: [Echoed]
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:value, :item_ref]

    @impl true
    def generator(overrides \\ %{}) do
      %{value: StreamData.integer(1..100)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule EchoProjection do
    @moduledoc false
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{count: 0}

    @impl true
    def apply(state, %Echo{}), do: %{state | count: state.count + 1}
    def apply(state, _), do: state
  end

  defmodule EchoChecks do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: 1
    def always_holds(_state, _cmd_or_event), do: :ok
  end

  defmodule EchoModel do
    @moduledoc false
    @behaviour PropertyDamage.Model
    @behaviour PropertyDamage.Model.Simulator

    @impl PropertyDamage.Model
    def commands, do: [Echo]

    @impl PropertyDamage.Model
    def command_sequence_projection, do: EchoProjection

    @impl PropertyDamage.Model
    def check_projections, do: [EchoChecks]

    @impl PropertyDamage.Model
    def simulator, do: __MODULE__

    @impl PropertyDamage.Model.Simulator
    def simulate(%Echo{value: value}, _state) do
      [%Echoed{value: value, item_ref: nil, id: nil, timestamp: nil}]
    end
  end

  defmodule PlainAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Echo{value: value}, _context, _runtime) do
      {:ok, [%Echoed{value: value, item_ref: "item", id: 1, timestamp: 1}]}
    end
  end

  defmodule ShiftedAdapter do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Echo{value: value}, _context, _runtime) do
      {:ok, [%Echoed{value: value + 100, item_ref: "item", id: 1, timestamp: 1}]}
    end
  end

  defmodule DiffRecorder do
    @moduledoc false
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      send(config.test_pid, {:diff_setup_config, config})
      {:ok, config}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%Echo{value: value}, _context, _runtime) do
      {:ok, [%Echoed{value: value, item_ref: "item", id: 1, timestamp: 1}]}
    end
  end

  defp diff_opts(targets) do
    [
      model: EchoModel,
      targets: targets,
      compare: :correctness,
      max_runs: 3,
      max_commands: 3,
      seed: 12_345,
      validate: false
    ]
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, config} -> drain(tag, [config | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ============================================================================
  # config: reaches Adapter.setup/1
  # ============================================================================

  describe "config reaches Adapter.setup/1 unchanged" do
    test "PropertyDamage.run/1 passes the target's config map as given" do
      config = %{"tenant" => "t-1", :nested => %{"k" => [1, 2]}, test_pid: self()}

      assert {:ok, _stats} =
               PropertyDamage.run(
                 model: ExecutorModel,
                 targets: [{RunRecorder, config: config}],
                 max_runs: 2,
                 max_commands: 3,
                 seed: 7
               )

      received = drain(:run_setup_config)
      assert received != []
      assert Enum.all?(received, &(&1 == config))
    end

    test "run/1 with two targets passes each target its own config map" do
      pid = self()
      config_a = %{"tenant" => "t-a", :nested => %{"k" => [1]}, test_pid: pid}
      config_b = %{"tenant" => "t-b", :nested => %{"k" => [2]}, test_pid: pid}

      assert {:ok, _stats} =
               PropertyDamage.run(
                 diff_opts([
                   {DiffRecorder, name: "a", config: config_a},
                   {DiffRecorder, name: "b", config: config_b}
                 ])
               )

      received = drain(:diff_setup_config)
      assert config_a in received
      assert config_b in received
      assert Enum.all?(received, &(&1 in [config_a, config_b]))
    end
  end

  # ============================================================================
  # Reference rule and variant naming
  # ============================================================================

  describe "the first target is the reference" do
    test "a divergent second target is reported by name" do
      assert {:error, %FailureReport{kind: :diverged} = report} =
               PropertyDamage.run(diff_opts([PlainAdapter, ShiftedAdapter]))

      assert report.variant == %{index: 1, name: "ShiftedAdapter"}
    end

    test "reversing the order moves the reference with the position" do
      assert {:error, %FailureReport{kind: :diverged} = report} =
               PropertyDamage.run(diff_opts([ShiftedAdapter, PlainAdapter]))

      assert report.variant == %{index: 1, name: "PlainAdapter"}
    end
  end

  describe "the result names every variant by index and name" do
    test "the stats and the report carry every target's index and name" do
      targets = [%{index: 0, name: "PlainAdapter"}, %{index: 1, name: "ShiftedAdapter"}]

      assert {:ok, %{targets: ^targets}} =
               PropertyDamage.run(
                 diff_opts([PlainAdapter, {ShiftedAdapter, name: "ShiftedAdapter"}])
                 |> Keyword.put(:equivalence, fn _, _ -> true end)
               )

      assert {:error, report} = PropertyDamage.run(diff_opts([PlainAdapter, ShiftedAdapter]))

      assert Enum.map(report.targets, fn {_adapter, entry} -> entry[:name] end) ==
               ["PlainAdapter", "ShiftedAdapter"]
    end

    test "the verbose output lists them, the reference first, and names the failing one" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PropertyDamage.run(diff_opts([PlainAdapter, ShiftedAdapter]) ++ [verbose: true])
        end)

      assert output =~ "[0] PlainAdapter"
      assert output =~ "[1] ShiftedAdapter"
      assert output =~ "Target:       [1] ShiftedAdapter"
    end
  end
end
