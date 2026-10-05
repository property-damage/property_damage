defmodule PropertyDamage.LockstepShrinkTest do
  # A failure in a run with one target or several is shrunk, reproduced and
  # replayed through the lockstep scheduler, and keeps its identity: the same
  # fine-grained kind, the same check name and the same failing target.
  #
  # Not async: the rejected-candidate probe is a registered process name.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Failure, FailureReport, Generator, Options, Scheduler, SeedLibrary}
  alias PropertyDamage.{Sequence, Shrinker}

  @probe :pd_lockstep_shrink_probe

  # ==========================================================================
  # Commands, events, projections
  # ==========================================================================

  defmodule Noise do
    use PropertyDamage.Command
    defstruct [:n]

    @impl true
    def generator(overrides \\ %{}) do
      %{n: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Arm do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Flip do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Noised, do: defstruct([:n])
  defmodule Armed, do: defstruct([])
  defmodule Flipped, do: defstruct([:value])

  defmodule Tally do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{noise: 0, armed: false}

    @impl true
    def apply(state, %Noised{}), do: %{state | noise: state.noise + 1}
    def apply(state, %Armed{}), do: %{state | armed: true}
    def apply(state, _), do: state
  end

  # Fails on a Flip that no Arm preceded. Every failure is reported to the
  # probe process, so a test can count the candidates that failed this way.
  defmodule ArmGuard do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{armed: false}

    @impl true
    def apply(state, %Armed{}), do: %{state | armed: true}
    def apply(state, _), do: state

    @check every: Flipped
    def assert_flip_is_armed(state, _event) do
      unless state.armed do
        if pid = Process.whereis(:pd_lockstep_shrink_probe), do: send(pid, :unarmed_flip)
        PropertyDamage.fail!("flip without arm")
      end

      :ok
    end
  end

  # A Flip diverges once two Noise commands ran before it.
  defmodule DivergeModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{Noise, weight: 3}, Flip]

    @impl true
    def command_sequence_projection, do: Tally

    def setup_each(%{adapter_config: config}) do
      if each = config[:each], do: :counters.add(each, 1, 1)
      :ok
    end
  end

  # A Flip diverges whenever it runs; without an Arm before it, it fails
  # ArmGuard first, in the reference target.
  defmodule ArmedModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{Noise, weight: 2}, Arm, Flip]

    @impl true
    def command_sequence_projection, do: Tally

    @impl true
    def check_projections, do: [ArmGuard]
  end

  # Config keys:
  #
  #   :skew       :after_two_noise | :always - answer Flip with value 1 instead
  #               of 0 (after two Noise commands in this run, or always)
  #   :counts     :counters ref; index 1 counts setups, index 2 teardowns
  defmodule FlipAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      if counts = config[:counts], do: :counters.add(counts, 1, 1)
      {:ok, Map.put(config, :noise, :atomics.new(1, []))}
    end

    @impl true
    def teardown(ctx) do
      if counts = ctx[:counts], do: :counters.add(counts, 2, 1)
      :ok
    end

    @impl true
    def execute(%Noise{n: n}, ctx, _runtime) do
      :atomics.add(ctx.noise, 1, 1)
      {:ok, [%Noised{n: n}]}
    end

    def execute(%Arm{}, _ctx, _runtime), do: {:ok, [%Armed{}]}

    def execute(%Flip{}, ctx, _runtime) do
      skewed? =
        case ctx[:skew] do
          :always -> true
          :after_two_noise -> :atomics.get(ctx.noise, 1) >= 2
          _ -> false
        end

      {:ok, [%Flipped{value: if(skewed?, do: 1, else: 0)}]}
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @max_commands 20

  defp targets(config_a \\ %{}, config_b \\ %{skew: :after_two_noise}) do
    [
      {FlipAdapter, name: "ref", config: config_a},
      {FlipAdapter, name: "cand", config: config_b}
    ]
  end

  defp run(model, targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          max_runs: 1,
          max_commands: @max_commands,
          validate: false
        ],
        extra
      )
    )
  end

  defp commands(model, seed) do
    model
    |> Generator.generate_sequence(max_commands: @max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, 0))
    |> Sequence.to_list()
  end

  defp find_seed(model, predicate) do
    Enum.find(1..20_000, fn seed -> predicate.(commands(model, seed)) end) ||
      flunk("no seed satisfies the fixture predicate")
  end

  # The index of the first Flip with at least two Noise commands before it.
  defp divergent_root(commands) do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn
      {%Noise{}, _i}, noise -> {:cont, noise + 1}
      {%Flip{}, i}, noise when noise >= 2 -> {:halt, {:root, i}}
      _, noise -> {:cont, noise}
    end)
    |> case do
      {:root, i} -> i
      _ -> nil
    end
  end

  # A generated sequence of at least 12 commands whose divergence is planted
  # at root 5 or later.
  defp planted_seed do
    find_seed(DivergeModel, fn commands ->
      root = divergent_root(commands)
      length(commands) >= 12 and is_integer(root) and root >= 5
    end)
  end

  defp signature(%FailureReport{} = report),
    do: Shrinker.failure_signature(report.failure_reason, report.variant.index)

  defp drain_probe(count \\ 0) do
    receive do
      :unarmed_flip -> drain_probe(count + 1)
    after
      0 -> count
    end
  end

  # ==========================================================================
  # Shrinking
  # ==========================================================================

  describe "a planted divergence" do
    test "shrinks to a shorter sequence failing at or before its root, in the same target" do
      seed = planted_seed()
      original = commands(DivergeModel, seed)
      root = divergent_root(original)

      assert {:error, %FailureReport{} = report} = run(DivergeModel, targets(), seed: seed)

      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "cand"}
      assert Failure.kind(report.failure_reason) == :diverged
      assert Sequence.to_list(report.original_sequence) == original
      assert length(original) >= 12

      shrunk = report |> FailureReport.shrunk_sequence() |> Sequence.to_list()
      assert length(shrunk) < length(original)
      assert report.failed_at_index <= root
      assert Enum.map(shrunk, & &1.__struct__) == [Noise, Noise, Flip]
      assert report.failed_at_index == 2
      assert report.shrink_iterations > 0
    end

    test "rejects a candidate that fails with another kind in another target" do
      seed =
        find_seed(ArmedModel, fn commands ->
          case Enum.find_index(commands, &match?(%Flip{}, &1)) do
            nil ->
              false

            flip ->
              before = Enum.take(commands, flip)
              Enum.any?(before, &match?(%Arm{}, &1)) and flip >= 3
          end
        end)

      Process.register(self(), @probe)

      try do
        assert {:error, report} =
                 run(ArmedModel, targets(%{}, %{skew: :always}), seed: seed)

        rejected = drain_probe()

        assert report.kind == :diverged
        assert report.variant.index == 1
        assert Failure.kind(report.failure_reason) == :diverged

        shrunk = report |> FailureReport.shrunk_sequence() |> Sequence.to_list()
        assert Enum.map(shrunk, & &1.__struct__) == [Arm, Flip]

        assert rejected >= 1,
               "expected at least one candidate to fail ArmGuard in the reference target"
      after
        Process.unregister(@probe)
      end
    end

    test "sets every target up and tears it down once per shrink attempt and reproduction" do
      seed = planted_seed()
      each = :counters.new(1, [])
      ref_counts = :counters.new(2, [])
      cand_counts = :counters.new(2, [])

      assert {:error, report} =
               run(
                 DivergeModel,
                 targets(
                   %{counts: ref_counts, each: each},
                   %{counts: cand_counts, skew: :after_two_noise}
                 ),
                 seed: seed
               )

      assert report.kind == :diverged
      # setup_each runs once for the exploration run and once before every
      # shrink attempt, so the shrinker's scheduler runs are the rest.
      shrink_runs = :counters.get(each, 1) - 1
      assert shrink_runs > 0

      for counts <- [ref_counts, cand_counts] do
        assert :counters.get(counts, 1) == 1 + shrink_runs + 1
        assert :counters.get(counts, 2) == 1 + shrink_runs + 1
      end
    end

    test "the on_failure report reproduces through the scheduler with the same identity" do
      seed = planted_seed()
      test_pid = self()

      assert {:error, _report} =
               run(DivergeModel, targets(),
                 seed: seed,
                 on_failure: fn report -> send(test_pid, {:on_failure, report}) end
               )

      assert_received {:on_failure, %FailureReport{} = report}

      {:ok, targets} = Options.validate_targets(report.targets)
      shrunk = FailureReport.shrunk_sequence(report)

      {:ok, rerun} =
        Scheduler.run(
          model: report.model,
          targets: targets,
          commands: Sequence.to_list(shrunk),
          placeholder_registry: shrunk.registry,
          seed: report.seed,
          run_number: 0,
          run_nonce: report.trace.run_nonce,
          mint_epoch: report.trace.mint_epoch + 1,
          concurrency: report.concurrency,
          compare: :correctness,
          equivalence: :exact
        )

      assert %{reason: reason, variant: %{index: index}} = rerun.failure
      assert Shrinker.failure_signature(reason, index) == signature(report)
      assert signature(report) == {:diverged, nil, 1}
    end
  end

  # ==========================================================================
  # Seed-library replay
  # ==========================================================================

  describe "seed-library replay" do
    @tag :capture_io
    test "replays a divergence seed against every target and halts with its report" do
      replayed = planted_seed()

      # Exploration would pass: its sequence never diverges.
      exploration = find_seed(DivergeModel, &is_nil(divergent_root(&1)))

      path =
        Path.join(
          System.tmp_dir!(),
          "pd_lockstep_replay_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)

      {:ok, library} = SeedLibrary.add_seed(SeedLibrary.new(), replayed, model: "DivergeModel")
      :ok = SeedLibrary.save(library, path)

      assert {:error, %FailureReport{} = report} =
               run(DivergeModel, targets(), seed: exploration, seed_library: path)

      assert report.seed == replayed
      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "cand"}
    end
  end

  # ==========================================================================
  # shrink_further/2
  # ==========================================================================

  describe "shrink_further/2" do
    test "re-shrinks a two-target divergence keeping its kind and target" do
      seed = planted_seed()

      assert {:error, report} = run(DivergeModel, targets(), seed: seed, shrink: false)
      assert report.kind == :diverged
      before = report |> FailureReport.shrunk_sequence() |> Sequence.command_count()

      assert {:ok, smaller} = PropertyDamage.shrink_further(report, strategy: :quick)

      assert smaller.kind == :diverged
      assert smaller.variant == report.variant
      assert signature(smaller) == signature(report)
      after_count = smaller |> FailureReport.shrunk_sequence() |> Sequence.command_count()
      assert after_count <= before
      assert after_count == 3
    end
  end
end
