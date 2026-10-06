defmodule PropertyDamage.SetupCommandsShrinkTest do
  # Shrinking keeps the setup commands out of every candidate: each attempt
  # executes them first, unchanged, and draws its teardown commands again
  # against the candidate. A candidate is validated from the state the setup
  # commands leave, and an attempt whose setup failed is never a reproduction.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{
    FailureReport,
    Generator,
    Placeholder,
    PlaceholderRegistry,
    Sequence,
    Shrinker
  }

  alias PropertyDamage.Test.SetupCommands

  alias PropertyDamage.Test.SetupCommands.{
    Act,
    Cleanup,
    CreateUser,
    Login,
    MakeThing,
    ThingMade,
    Tick
  }

  # ==========================================================================
  # A planted divergence with one setup command
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

  defmodule Flip do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  # The setup command; the adapter counts it per target.
  defmodule Count do
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{})
  end

  defmodule Noised, do: defstruct([:n])
  defmodule Flipped, do: defstruct([:value])

  defmodule Tally do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{noise: 0}

    @impl true
    def apply(state, %Noised{}), do: %{state | noise: state.noise + 1}
    def apply(state, _), do: state
  end

  defmodule Answers do
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{flips: []}

    @impl true
    def apply(state, %Flipped{value: v}), do: %{state | flips: [v | state.flips]}
    def apply(state, _), do: state

    @compare every: 1
    def flips(state, _root), do: state.flips
  end

  defmodule CountedModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [{Noise, weight: 3}, Flip]

    @impl true
    def command_sequence_projection, do: Tally

    @impl true
    def check_projections, do: [Answers]

    @impl true
    def setup_each, do: [Count]
  end

  # Config keys:
  #
  #   :counts       :counters ref counting this target's Count commands
  #   :fail_count   the Count execution (1-based) that answers an error, or
  #                 :always
  #   :skew         answer a Flip with 1 once two Noise commands ran
  defmodule FlipAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.put(config, :noise, :atomics.new(1, []))}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Count{}, ctx, _runtime) do
      :counters.add(ctx.counts, 1, 1)
      n = :counters.get(ctx.counts, 1)

      case ctx[:fail_count] do
        :always -> {:error, :flaky_login}
        ^n -> {:error, :flaky_login}
        _ -> {:ok, []}
      end
    end

    def execute(%Noise{n: n}, ctx, _runtime) do
      :atomics.add(ctx.noise, 1, 1)
      {:ok, [%Noised{n: n}]}
    end

    def execute(%Flip{}, ctx, _runtime) do
      skewed? = ctx[:skew] == true and :atomics.get(ctx.noise, 1) >= 2
      {:ok, [%Flipped{value: if(skewed?, do: 1, else: 0)}]}
    end
  end

  # ==========================================================================
  # Fixture-world projections
  # ==========================================================================

  defmodule TwoThings do
    # Fails at the end of a run that made two things or more.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{things: 0}

    @impl true
    def apply(state, %ThingMade{}), do: %{state | things: state.things + 1}
    def apply(state, _), do: state

    @check at: :teardown
    def assert_fewer_than_two_things(state, _phase) do
      if state.things >= 2, do: PropertyDamage.fail!("two things made"), else: :ok
    end
  end

  defmodule TwoActs do
    # Fails at the end of a run that acted twice or more.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.SetupCommands.Acted

    @impl true
    def init, do: %{acts: 0}

    @impl true
    def apply(state, %Acted{}), do: %{state | acts: state.acts + 1}
    def apply(state, _), do: state

    @check at: :teardown
    def assert_fewer_than_two_acts(state, _phase) do
      if state.acts >= 2, do: PropertyDamage.fail!("acted twice"), else: :ok
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @max_commands 12

  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  defp roots(model, seed) do
    model
    |> Generator.generate_sequence(max_commands: @max_commands)
    |> Generator.generate_value(seed)
    |> Sequence.to_list()
  end

  defp find_seed(model, predicate) do
    Enum.find(1..5_000, fn seed -> predicate.(roots(model, seed)) end) ||
      flunk("no seed satisfies the fixture predicate")
  end

  defp count(commands, module), do: Enum.count(commands, &(&1.__struct__ == module))

  # The first Flip with two Noise commands before it, or nil.
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

  defp planted_seed do
    find_seed(CountedModel, fn commands ->
      root = divergent_root(commands)
      length(commands) >= 8 and is_integer(root) and root >= 4
    end)
  end

  defp flip_targets(ref_config, cand_config) do
    [
      {FlipAdapter, name: "ref", config: Map.merge(%{counts: :counters.new(1, [])}, ref_config)},
      {FlipAdapter,
       name: "cand", config: Map.merge(%{counts: :counters.new(1, []), skew: true}, cand_config)}
    ]
  end

  defp run(model, targets, extra) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          max_runs: 1,
          max_commands: @max_commands,
          compare: [converge_within: 30],
          validate: false
        ],
        extra
      )
    )
  end

  # The recorder entries of target `name`, split into one list per execution:
  # each starts at its `setup/1` and ends at its `teardown/1`.
  defp executions(entries, name) do
    entries
    |> SetupCommands.of(name)
    |> Enum.chunk_while(
      [],
      fn
        {:teardown, ^name} = entry, acc -> {:cont, Enum.reverse([entry | acc]), []}
        entry, acc -> {:cont, [entry | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp executed_in(execution), do: for({:execute, _name, command} <- execution, do: command)

  # Every execution ran the setup commands first, and its teardown command
  # named the id of the last thing that execution made (nil when it made
  # none): the adapter mints the user first, then one id per thing.
  defp assert_cleanup_names_last_thing(executions, name) do
    for execution <- executions do
      assert [%CreateUser{name: "fixture"}, %Login{} | rest] = executed_in(execution)

      made = count(rest, MakeThing)
      expected = if made == 0, do: nil, else: "#{name}-t#{made + 1}"

      assert [%Cleanup{thing_id: ^expected}] = Enum.filter(rest, &match?(%Cleanup{}, &1)),
             "execution #{inspect(executed_in(execution))} did not clean up #{inspect(expected)}"

      assert %Cleanup{} = List.last(rest)
    end
  end

  defp things_model(name) do
    model!(name,
      commands: [MakeThing, Tick],
      checks: [TwoThings],
      setup: SetupCommands.standard_setup(),
      teardown: [{Cleanup, overrides: fn state -> %{thing_id: List.last(state.things)} end}]
    )
  end

  defp things_seed(model) do
    find_seed(model, fn commands ->
      count(commands, MakeThing) >= 3 and count(commands, Tick) >= 2
    end)
  end

  # ==========================================================================
  # Tests
  # ==========================================================================

  describe "an attempt whose setup failed" do
    test "is rejected and counted, and the shrunk sequence comes from a later attempt" do
      seed = planted_seed()
      original = roots(CountedModel, seed)
      ref = %{counts: :counters.new(1, [])}
      # The candidate target's second Count is the first shrink attempt's.
      cand = %{counts: :counters.new(1, []), fail_count: 2}

      assert {:error, %FailureReport{} = report} =
               run(CountedModel, flip_targets(ref, cand), seed: seed)

      assert report.kind == :diverged
      assert report.variant == %{index: 1, name: "cand"}

      assert Shrinker.failure_signature(report.failure_reason, 1) ==
               {:diverged, {Answers, :flips}, 1}

      shrunk = FailureReport.shrunk_sequence(report)
      assert shrunk |> Sequence.to_list() |> Enum.map(& &1.__struct__) == [Noise, Noise, Flip]
      assert length(original) > 3
      refute Enum.any?(Sequence.to_list(shrunk), &match?(%Count{}, &1))
      assert Sequence.setup_commands(shrunk) == [%Count{}]
      assert report.setup_commands == [%Count{}]

      # The exploration run, every shrink attempt (the failed one included)
      # and the reproduction each executed Count once per target.
      for counts <- [ref.counts, cand.counts] do
        assert :counters.get(counts, 1) == 1 + report.shrink_iterations + 1
      end
    end

    test "is not a reproduction when the original failure has no signature" do
      seed = planted_seed()
      sequence = CountedModel |> Generator.generate_sequence(max_commands: @max_commands)
      sequence = Generator.generate_value(sequence, seed)
      root = divergent_root(Sequence.to_list(sequence))

      result =
        Shrinker.shrink(sequence,
          failed_at_index: root,
          model: CountedModel,
          targets: targets!(flip_targets(%{}, %{fail_count: :always})),
          compare: [converge_within: 30],
          rng_seed: seed
        )

      assert Sequence.to_list(result.sequence) == Sequence.to_list(sequence)
      assert result.iterations > 0
    end
  end

  describe "every shrink attempt" do
    test "executes the setup commands and draws its teardown commands against its own roots" do
      recorder = start_recorder()
      model = things_model(Redrawn)
      seed = things_seed(model)

      log =
        capture_log(fn ->
          assert {:error, %FailureReport{} = report} =
                   run(model, [SetupCommands.target("a", recorder)], seed: seed)

          send(self(), {:report, report})
        end)

      assert_received {:report, report}
      assert report.kind == :check_failed
      shrunk = FailureReport.shrunk_sequence(report)
      assert shrunk |> Sequence.to_list() |> Enum.map(& &1.__struct__) == [MakeThing, MakeThing]

      executions = executions(recorded(recorder), "a")
      # The exploration run, one execution per attempt, the reproduction.
      assert length(executions) == 1 + report.shrink_iterations + 1
      assert report.shrink_iterations > 0
      assert_cleanup_names_last_thing(executions, "a")
      refute log =~ "skipped"

      # The shrunk sequence carries its own teardown command, drawn against
      # its last root.
      assert [%Cleanup{thing_id: %Placeholder{} = thing}] =
               Sequence.teardown_commands(shrunk)

      {last_root, _index, _command} = shrunk |> Sequence.indexed() |> List.last()
      assert thing.id in PlaceholderRegistry.ids_at_position(shrunk.registry, last_root)
      assert report.teardown_commands == Sequence.teardown_commands(shrunk)
    end

    test "validates a candidate from the state the setup commands leave" do
      model =
        model!(PostSetup,
          commands: [
            {Tick, when: fn state -> state.user != nil end}
            | SetupCommands.act_roots()
          ],
          checks: [TwoActs],
          setup: SetupCommands.standard_setup()
        )

      seed =
        find_seed(model, fn commands ->
          count(commands, Act) >= 2 and count(commands, Tick) >= 2
        end)

      assert {:error, %FailureReport{} = report} =
               run(model, [SetupCommands.target("a", start_recorder())], seed: seed)

      assert report.kind == :check_failed

      assert report
             |> FailureReport.shrunk_sequence()
             |> Sequence.to_list()
             |> Enum.map(& &1.__struct__) ==
               [Act, Act]
    end
  end

  describe "shrink_further/2" do
    test "executes the setup commands and a teardown drawn against each attempt" do
      recorder = start_recorder()
      model = things_model(Further)
      seed = things_seed(model)

      capture_log(fn ->
        assert {:error, %FailureReport{} = report} =
                 run(model, [SetupCommands.target("a", recorder)], seed: seed, shrink: false)

        before = length(executions(recorded(recorder), "a"))

        assert {:ok, smaller} = PropertyDamage.shrink_further(report, strategy: :quick)

        assert smaller |> FailureReport.shrunk_sequence() |> Sequence.to_list() |> length() == 2

        executions = recorded(recorder) |> executions("a") |> Enum.drop(before)
        assert length(executions) == 1 + (smaller.shrink_iterations - report.shrink_iterations)
        assert_cleanup_names_last_thing(executions, "a")
        assert smaller.setup_commands == report.setup_commands
      end)
    end
  end
end
