defmodule CachexBench.ExpansionsTest do
  @moduledoc """
  Path equivalence against a real Cachex: an `Incr k n` root may run, per
  target, as itself or as two increments that add up to `n`
  (`Incr k 5` runs as `[Incr k 2, Incr k 3]`: the first leaf adds
  `div(n, 2)`). Both mean the same once the root is done, and
  `CachexBench.Projection.expected_contents/2` compares the targets after
  every root.

  The targets are two caches behind the same adapter: `setup/1` starts a
  fresh, uniquely named cache per target.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CachexBench.Commands.{GetKey, Incr, PutKey}
  alias PropertyDamage.{FailureReport, Sequence, Shrinker}

  # Found by running seeds 1, 2, ... with the second target's `incr_bug:` on:
  # the first seed whose first divergence is at a root where "second" ran the
  # two-step rewrite (an identity Incr of 1 or 2 also trips the bug).
  @bug_seed 2

  # A seed whose one sampled root sequence offers the rewrite and realizes
  # it in neither target (found by sampling seeds 1, 2, ... with
  # `--seeds 1`).
  @unrealized_seed 18

  defp targets(second_config \\ %{}) do
    [
      {CachexBench.Adapter, name: "cachex"},
      {CachexBench.Adapter, name: "second", config: second_config}
    ]
  end

  defp run(opts) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: CachexBench.Model,
          targets: targets(),
          max_commands: 30,
          # The caches answer at once: a divergence needs no time to settle,
          # and a short bound keeps each shrink attempt short.
          compare: [converge_within: 50],
          verbose: false
        ],
        opts
      )
    )
  end

  describe "two targets on expansion: :random" do
    test "agree over 100 runs and realize both entries" do
      assert {:ok, stats} = run(max_runs: 100, seed: 20_261_006)

      for name <- ["cachex", "second"] do
        counts = stats.expansion_counts |> Map.fetch!(name) |> Map.fetch!(Incr)
        assert Map.get(counts, "Incr[0]", 0) > 0, "#{name} never ran Incr as itself"
        assert Map.get(counts, "Incr[1]", 0) > 0, "#{name} never ran the two-step rewrite"
      end
    end
  end

  describe "a bug only the two-step path exposes" do
    # The second target's adapter adds one too much for an Incr below 3, which
    # a split of `n` in 2..5 always sends.
    test "is reported as a divergence at the root that chose the rewrite, and shrinks" do
      assert {:error, %FailureReport{} = report} =
               run(targets: targets(%{incr_bug: true}), max_runs: 1, seed: @bug_seed)

      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "second"}

      signature = {:diverged, {CachexBench.Projection, :expected_contents}, 1}
      assert Shrinker.failure_signature(report.failure_reason, report.variant.index) == signature

      roots = report |> FailureReport.shrunk_sequence() |> Sequence.to_list()
      assert length(roots) < length(Sequence.to_list(report.original_sequence))
      assert %Incr{amount: n} = Enum.at(roots, report.failed_at_index)
      assert n >= 2

      assert %{entry: "Incr[1]", leaves: [Incr, Incr]} =
               report.expansions |> Map.fetch!("second") |> Enum.at(report.failed_at_index)

      # The report describes the reproduction of the shrunk sequence: it
      # failed again with the same kind, observation and target.
      assert report.trace.plan_source == :shrunk
    end
  end

  describe "determinism" do
    # What each target ran at each root of the bug seed's run, unshrunk: the
    # draw depends only on the seed, the run and the target names, so any OS
    # process on any machine prints the same list.
    test "the expansions of a fixed seed and names equal a pinned value" do
      assert {:error, %FailureReport{} = report} =
               run(
                 targets: targets(%{incr_bug: true}),
                 max_runs: 1,
                 seed: @bug_seed,
                 shrink: false
               )

      entries =
        Map.new(report.expansions, fn {name, ran} -> {name, Enum.map(ran, & &1.entry)} end)

      assert entries == golden()
    end
  end

  describe "mix pd.validate --seeds" do
    @validate_targets ~s([CachexBench.Adapter, {CachexBench.Adapter, name: "second"}])

    defp validate(args) do
      output =
        capture_io(fn ->
          status =
            Mix.Tasks.Pd.Validate.exec([
              "CachexBench.Model",
              "--targets",
              @validate_targets | args
            ])

          send(self(), {:status, status})
        end)

      assert_received {:status, status}
      {status, output}
    end

    test "prints each entry key with its realization count" do
      {status, output} = validate(["--seeds", "20"])

      assert status == :ok
      assert output =~ ~r/Incr\[0\] = \[Incr\]\s+realized \d+/
      assert output =~ ~r/Incr\[1\] = \[Incr, Incr\]\s+realized \d+/
    end

    test "prints Incr[1] as not realized for a seed whose sample never drew it" do
      {status, output} = validate(["--seed", "#{@unrealized_seed}", "--seeds", "1"])

      assert status == :ok
      assert output =~ "Incr[1] = [Incr, Incr]  not realized in 1 seeds"
    end
  end

  describe "a model listing a non-root module in expansions/0" do
    defmodule NonRootModel do
      @moduledoc false
      @behaviour PropertyDamage.Model

      @impl true
      def commands, do: [CachexBench.Commands.PutKey, CachexBench.Commands.Incr]

      @impl true
      def command_sequence_projection, do: CachexBench.Projection

      @impl true
      def check_projections, do: [CachexBench.Projection]

      @impl true
      def simulator, do: CachexBench.Simulator

      @impl true
      def expansions, do: [{CachexBench.Commands.GetKey, fn get, _state -> [[get]] end}]
    end

    test "fails at run start naming the module" do
      error =
        assert_raise ArgumentError, fn ->
          PropertyDamage.run(model: NonRootModel, targets: [CachexBench.Adapter], max_runs: 1)
        end

      assert error.message =~ inspect(GetKey)
      assert error.message =~ "expansions/0"
      refute error.message =~ inspect(PutKey)
    end
  end

  # Root 2 ran as itself in both targets; root 28, the failing root, ran as
  # the rewrite in both. No other root of this run is an Incr.
  defp golden do
    ran =
      List.duplicate(nil, 29) |> List.replace_at(2, "Incr[0]") |> List.replace_at(28, "Incr[1]")

    %{"cachex" => ran, "second" => ran}
  end
end
