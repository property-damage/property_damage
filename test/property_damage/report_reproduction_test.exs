defmodule PropertyDamage.ReportReproductionTest do
  # A failure report carries what reproducing its run needs: a kind that agrees
  # with its failure reason, and the run's `compare:`, `stutter:` and
  # `max_commands:`, which `reproduction_command/1` prints and
  # `shrink_further/2` reuses.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Generator, Persistence, Sequence}

  # ==========================================================================
  # Commands, events, projection, model
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
  defmodule Flipped, do: defstruct([:value, :ts])

  defmodule Tally do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state
  end

  # What the targets are compared on: the values their Flips answered, without
  # the timestamps.
  defmodule Answers do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: []

    @impl true
    def apply(values, %Flipped{value: value}), do: [value | values]
    def apply(values, _event), do: values

    @compare every: 1
    def flips(values, _root), do: values
  end

  defmodule Model do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{Noise, weight: 2}, Arm, Flip]

    @impl true
    def command_sequence_projection, do: Tally

    @impl true
    def check_projections, do: [Answers]
  end

  # Config keys:
  #
  #   :poll     every Flip starts a resource poller that never settles and
  #             fails when the run finalizes
  #   :ts_skew  answer Flip with ts 1 instead of 0
  #   :flip     :armed - answer an armed Flip with value 1;
  #             :counter - answer an armed Flip with a counter that grows on
  #             every call, so a repeated Flip answers differently
  defmodule Adapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      {:ok,
       config
       |> Map.put(:armed, :atomics.new(1, []))
       |> Map.put(:counter, :atomics.new(1, []))}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Noise{n: n}, _ctx, _runtime), do: {:ok, [%Noised{n: n}]}

    def execute(%Arm{}, ctx, _runtime) do
      :atomics.put(ctx.armed, 1, 1)
      {:ok, [%Armed{}]}
    end

    def execute(%Flip{}, ctx, runtime) do
      if ctx[:poll] do
        runtime.start_poller.(
          poll_fn: fn -> :pending end,
          handler: fn _ -> :continue end,
          interval_ms: 5,
          timeout_ms: 30,
          on_timeout: :fail
        )
      end

      armed? = :atomics.get(ctx.armed, 1) == 1

      value =
        case ctx[:flip] do
          :armed when armed? -> 1
          :counter when armed? -> :atomics.add_get(ctx.counter, 1, 1) - 1
          _ -> 0
        end

      {:ok, [%Flipped{value: value, ts: if(ctx[:ts_skew], do: 1, else: 0)}]}
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @max_commands 20
  @converge_within 40

  defp run(targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: Model,
          targets: targets,
          max_runs: 1,
          max_commands: @max_commands,
          compare: [converge_within: @converge_within],
          validate: false
        ],
        extra
      )
    )
  end

  defp commands(seed) do
    Model
    |> Generator.generate_sequence(max_commands: @max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, 0))
    |> Sequence.to_list()
  end

  defp find_seed(predicate) do
    Enum.find(1..20_000, &predicate.(commands(&1))) || flunk("no seed satisfies the predicate")
  end

  # An Arm, then at least one other command, then a Flip.
  defp armed_flip_seed do
    find_seed(fn commands ->
      arm = Enum.find_index(commands, &match?(%Arm{}, &1))
      flip = Enum.find_index(commands, &match?(%Flip{}, &1))
      arm != nil and flip != nil and flip - arm >= 2
    end)
  end

  defp shrunk_modules(report) do
    report |> FailureReport.shrunk_sequence() |> Sequence.to_list() |> Enum.map(& &1.__struct__)
  end

  defp assert_kind_agrees(%FailureReport{} = report) do
    assert report.kind == FailureReport.kind_of(report.failure_reason)
  end

  defp reproduce(report) do
    {result, _binding} = Code.eval_string(FailureReport.reproduction_command(report))
    result
  end

  # ==========================================================================
  # Tests
  # ==========================================================================

  describe "a failure found while the run finalizes" do
    for count <- [1, 2] do
      test "of the execution class is :execution_failed (#{count} target(s))" do
        targets =
          Enum.take(
            [
              {Adapter, name: "ref", config: %{poll: true}},
              {Adapter, name: "cand", config: %{poll: true}}
            ],
            unquote(count)
          )

        seed = find_seed(&Enum.any?(&1, fn command -> match?(%Flip{}, command) end))
        assert {:error, report} = run(targets, seed: seed)

        assert %Failure{type: %Failure.Execution{kind: :resource_poller_error}} =
                 report.failure_reason

        assert report.kind == :execution_failed
        assert_kind_agrees(report)
      end
    end
  end

  describe "a run with a non-default convergence bound" do
    defp skewed_targets do
      [
        {Adapter, name: "ref"},
        {Adapter, name: "ts", config: %{ts_skew: true}},
        {Adapter, name: "val", config: %{flip: :armed}}
      ]
    end

    test "is reproduced by the report's reproduction command and re-shrunk under it" do
      seed = armed_flip_seed()

      # The observation folds Flip values, not timestamps: "ts" agrees with the
      # reference and "val" diverges.
      assert {:error, report} = run(skewed_targets(), seed: seed)
      assert_kind_agrees(report)
      assert report.kind == :diverged
      assert report.variant.index == 2
      assert report.compare == [converge_within: @converge_within]
      assert report.max_commands == @max_commands

      command = FailureReport.reproduction_command(report)
      assert command =~ "compare: [converge_within: #{@converge_within}]"
      assert command =~ "max_commands: #{@max_commands}"

      assert {:error, repro} = reproduce(report)
      assert_kind_agrees(repro)
      assert repro.kind == :diverged
      assert repro.variant.index == 2

      assert {:error, unshrunk} = run(skewed_targets(), seed: seed, shrink: false)

      assert {:ok, smaller} = PropertyDamage.shrink_further(unshrunk, strategy: :quick)
      assert_kind_agrees(smaller)
      assert smaller.variant.index == 2
      assert smaller.compare == report.compare
      assert shrunk_modules(smaller) == [Arm, Flip]
    end

    test "is exported to JSON with the bound and the compare counts" do
      seed = armed_flip_seed()

      assert {:error, report} = run(skewed_targets(), seed: seed)

      exported = Jason.decode!(Persistence.export_json(report))
      assert exported["compare"] == %{"converge_within" => @converge_within}

      assert %{"compared_at" => compared_at} =
               exported["compare_counts"]["#{inspect(Answers)}.flips"]

      assert compared_at > 0
    end
  end

  describe "shrink_further/2 and the convergence bound" do
    test "re-shrinks under compare: when given, and rejects the removed equivalence:" do
      seed = armed_flip_seed()

      assert {:error, unshrunk} =
               run(
                 [{Adapter, name: "ref"}, {Adapter, name: "val", config: %{flip: :armed}}],
                 seed: seed,
                 shrink: false
               )

      assert {:ok, smaller} =
               PropertyDamage.shrink_further(unshrunk,
                 strategy: :quick,
                 compare: [converge_within: 25]
               )

      assert smaller.compare == [converge_within: 25]

      error =
        assert_raise ArgumentError, fn ->
          PropertyDamage.shrink_further(unshrunk, equivalence: :structural)
        end

      assert error.message =~ "@compare"
      assert error.message =~ "using:"
    end
  end

  describe "a stutter failure" do
    @stutter [probability: 1.0, max_repeats: 1, commands: [Flip]]

    defp counter_targets,
      do: [{Adapter, name: "ref"}, {Adapter, name: "cand", config: %{flip: :counter}}]

    test "is reproduced by the report's reproduction command and re-shrunk with stutter" do
      seed = armed_flip_seed()

      assert {:error, report} = run(counter_targets(), seed: seed, stutter: @stutter)
      assert_kind_agrees(report)
      assert Failure.kind(report.failure_reason) == :idempotency_violation
      assert report.variant.index == 1
      assert report.stutter[:probability] == 1.0
      assert report.stutter[:commands] == [Flip]

      assert FailureReport.reproduction_command(report) =~ "stutter: ["

      assert {:error, repro} = reproduce(report)
      assert_kind_agrees(repro)
      assert Failure.kind(repro.failure_reason) == :idempotency_violation
      assert repro.variant.index == 1

      assert {:error, unshrunk} =
               run(counter_targets(), seed: seed, stutter: @stutter, shrink: false)

      assert {:ok, smaller} = PropertyDamage.shrink_further(unshrunk, strategy: :quick)
      assert_kind_agrees(smaller)
      assert Failure.kind(smaller.failure_reason) == :idempotency_violation
      assert smaller.stutter == unshrunk.stutter
      assert shrunk_modules(smaller) == [Arm, Flip]
    end
  end
end
