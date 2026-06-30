defmodule PropertyDamage.SeedLibraryReplayTest do
  @moduledoc """
  Integration tests for the seed-library replay phase of `PropertyDamage.run/1`
  (DR-023): replay-before-exploration, streak/prune lifecycle, halt-with-summary,
  auto-append, and default-off behavior.

  Not `async`: the model's pass/fail behavior is toggled through a global
  `:persistent_term` switch so the same model can be made to "still fail" or
  "now pass" across separate `run/1` invocations.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{ReplayUpdate, RunUpdate}
  alias PropertyDamage.SeedLibrary

  @switch {__MODULE__.Switchable, :mode}

  defmodule Cmd do
    use PropertyDamage.Command
    defstruct [:n]
    @impl true
    def generator(_overrides), do: StreamData.fixed_map(%{n: StreamData.integer(0..10)})
  end

  defmodule State do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state
  end

  defmodule Switchable do
    use PropertyDamage.Model.Projection
    def init, do: %{}
    def apply(state, _), do: state

    @trigger every: 1
    def assert_mode(_state, _cmd_or_event) do
      case :persistent_term.get({__MODULE__, :mode}, :fail) do
        :fail -> PropertyDamage.fail!("switched to fail")
        :pass -> :ok
      end
    end
  end

  defmodule Model do
    @behaviour PropertyDamage.Model
    def commands, do: [Cmd]
    def command_sequence_projection, do: State
    def assertion_projections, do: [Switchable]
  end

  defmodule Adapter do
    use PropertyDamage.Adapter
    def setup(config), do: {:ok, config}
    def teardown(_context), do: :ok
    def execute(_command, _context, _runtime), do: {:ok, []}
  end

  setup do
    set_mode(:fail)
    on_exit(fn -> :persistent_term.erase(@switch) end)
    :ok
  end

  defp set_mode(mode), do: :persistent_term.put(@switch, mode)

  defp tmp_path(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "pd_replay_#{name}_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp run(opts) do
    PropertyDamage.run(
      [model: Model, adapter: Adapter, max_commands: 2, shrink: false, validate: false] ++ opts
    )
  end

  defp preseed(path, seed, opts) do
    {:ok, lib} = SeedLibrary.add_seed(SeedLibrary.new(), seed, opts)
    :ok = SeedLibrary.save(lib, path)
  end

  defp entry(path, seed) do
    {:ok, lib} = SeedLibrary.load(path)
    Enum.find(lib.entries, &(&1.seed == seed))
  end

  defp drain_progress(acc) do
    receive do
      {:progress, data} -> drain_progress([data | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "default-off neither reads nor writes a seed library file" do
    default = "property_damage_seeds.json"
    preexisting = File.exists?(default)

    set_mode(:fail)
    assert {:error, _} = run(max_runs: 2)

    unless preexisting do
      refute File.exists?(default), "default-off must not create #{default}"
    end
  end

  test "a new exploration failure's seed is appended (deduplicated)" do
    path = tmp_path("append")
    set_mode(:fail)

    assert {:error, report} = run(seed_library: path, max_runs: 3)
    assert {:ok, lib} = SeedLibrary.load(path)
    assert Enum.any?(lib.entries, &(&1.seed == report.seed))

    # A second run rediscovers the same seed first via replay and halts; no
    # duplicate entry is appended.
    assert {:error, _} = run(seed_library: path, max_runs: 3)
    {:ok, lib2} = SeedLibrary.load(path)
    assert Enum.count(lib2.entries, &(&1.seed == report.seed)) == 1
  end

  test "a passing replay increments the streak; the Kth consecutive pass prunes" do
    path = tmp_path("streak")
    preseed(path, 4242, model: "M")
    set_mode(:pass)

    assert {:ok, _} = run(seed_library: path, seed_library_prune_after: 2, max_runs: 1)
    assert entry(path, 4242).consecutive_passes == 1

    # Second consecutive pass reaches K=2 and prunes the entry.
    assert {:ok, _} = run(seed_library: path, seed_library_prune_after: 2, max_runs: 1)
    refute entry(path, 4242)
  end

  test "a still-failing replay halts before exploration, resetting the streak" do
    path = tmp_path("halt")
    preseed(path, 777, model: "M", failure_type: :check_failed)

    # Give it an existing streak so we can observe the reset.
    {:ok, lib} = SeedLibrary.load(path)
    lib = %{lib | entries: Enum.map(lib.entries, &Map.put(&1, :consecutive_passes, 2))}
    :ok = SeedLibrary.save(lib, path)

    set_mode(:fail)
    test_pid = self()
    on_progress = fn %Progress{data: data} -> send(test_pid, {:progress, data}) end

    # max_runs is large: if exploration ran it would dominate, but the halt
    # returns immediately after the replay pass.
    assert {:error, report} = run(seed_library: path, max_runs: 50, on_progress: on_progress)

    # The representative report is the library seed, re-derived at run 0.
    assert report.seed == 777
    assert entry(path, 777).consecutive_passes == 0

    updates = drain_progress([])

    # Exploration is skipped: no per-run heartbeat fired (replays don't consume
    # max_runs).
    refute Enum.any?(updates, &match?(%RunUpdate{phase: :run}, &1))

    # The replay phase reported through the unified reporter.
    assert Enum.any?(updates, &match?(%ReplayUpdate{phase: :start}, &1))

    assert Enum.any?(updates, fn
             %ReplayUpdate{phase: :summary, halted?: true, still_failing: f} -> f >= 1
             _ -> false
           end)
  end

  test "the start banner and halt summary print unconditionally (no verbose)" do
    path = tmp_path("banner")
    preseed(path, 555, model: "M")
    set_mode(:fail)

    output = capture_io(fn -> assert {:error, _} = run(seed_library: path, max_runs: 5) end)

    assert output =~ "Seed Library Replay"
    assert output =~ "Disable with: seed_library: false"
    assert output =~ "halted exploration"
    assert output =~ "Still failing:"
  end
end
