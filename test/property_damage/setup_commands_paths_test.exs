defmodule PropertyDamage.SetupCommandsPathsTest do
  # Every path that executes a run's sequence again runs its setup commands
  # before the roots and its teardown commands after them: a branching run,
  # the branching shrink attempt and reproduction, the seed-library replay,
  # `PropertyDamage.replay/2`, `RunTrace.capture/1` and
  # `Analysis.isolate_trigger/2`. A check failure that belongs to a setup
  # command is a setup failure on every path.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{
    Analysis,
    Executor,
    Failure,
    FailureReport,
    Generator,
    Placeholder,
    PlaceholderRegistry,
    RunTrace,
    SeedLibrary,
    Sequence,
    Shrinker
  }

  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.SetupCommands

  alias PropertyDamage.Test.SetupCommands.{
    Act,
    Cleanup,
    CreateUser,
    Login,
    MakeThing,
    ThingMade,
    Tick,
    UserCreated
  }

  # ==========================================================================
  # Fixtures
  # ==========================================================================

  defmodule TwoThings do
    # Fails on the second thing a run makes. A synchronous check rather than
    # an `at: :teardown` one, which the linearization check of a branching
    # run cannot evaluate.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{things: 0}

    @impl true
    def apply(state, %ThingMade{}), do: %{state | things: state.things + 1}
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.SetupCommands.ThingMade
    def assert_fewer_than_two_things(state, _event) do
      if state.things >= 2, do: PropertyDamage.fail!("two things made"), else: :ok
    end
  end

  defmodule NoSimulatorModel do
    # Act roots checked by the fixture projection, with no simulator: the
    # linearization check of a branching run is then indeterminate and runs
    # no check (it cannot evaluate the fixture's `at: :teardown` check).
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [PropertyDamage.Test.SetupCommands.Act]

    @impl true
    def command_sequence_projection, do: PropertyDamage.Test.SetupCommands.World

    @impl true
    def check_projections, do: [PropertyDamage.Test.SetupCommands.Fixture]
  end

  defmodule SecondActFails do
    # Fails on the event of the Act whose `n` is 1 (the second Act root).
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.SetupCommands.Acted
    def assert_not_second_act(_state, %{n: n}) do
      if n == 1, do: PropertyDamage.fail!("the second act"), else: :ok
    end
  end

  defmodule LoginNeverSettles do
    # Opens an `@eventually` window on the Login setup command's event that
    # never closes.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @eventually after: PropertyDamage.Test.SetupCommands.LoggedIn,
                timeout: {100, :milliseconds},
                interval: {10, :milliseconds}
    def login_settles(_state, _event), do: fn _state -> false end
  end

  defmodule EveryThirdRoot do
    # Sends the Tick count each time its `every: 3` check fires.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{ticks: 0}

    @impl true
    def apply(state, %PropertyDamage.Test.SetupCommands.Tick{}),
      do: %{state | ticks: state.ticks + 1}

    def apply(state, _other), do: state

    @check every: 3
    def assert_sampled(state, _item) do
      send(:persistent_term.get({PropertyDamage.SetupCommandsPathsTest, :every3}), {
        :every3,
        state.ticks
      })

      :ok
    end
  end

  defmodule SlowAdapter do
    # The fixture adapter, with every root slowed down so an `@eventually`
    # window opened during setup expires while the roots run.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.SetupCommands.{Act, FixtureAdapter}

    @impl true
    def setup(config), do: FixtureAdapter.setup(config)

    @impl true
    def teardown(ctx), do: FixtureAdapter.teardown(ctx)

    @impl true
    def execute(%Act{} = command, ctx, runtime) do
      Process.sleep(60)
      FixtureAdapter.execute(command, ctx, runtime)
    end

    def execute(command, ctx, runtime), do: FixtureAdapter.execute(command, ctx, runtime)
  end

  defmodule FlakyLoginAdapter do
    # The fixture adapter whose Login answers an error on the execution
    # `:fail_login` names (1-based, counted in the `:logins` counters ref).
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.SetupCommands.{FixtureAdapter, Login}
    alias PropertyDamage.Test.VariantSupport

    @impl true
    def setup(config), do: FixtureAdapter.setup(config)

    @impl true
    def teardown(ctx), do: FixtureAdapter.teardown(ctx)

    @impl true
    def execute(%Login{} = command, ctx, runtime) do
      :counters.add(ctx.logins, 1, 1)

      if :counters.get(ctx.logins, 1) == ctx.fail_login do
        VariantSupport.record(ctx.recorder, {:execute, ctx.name, command})
        {:error, :flaky_login}
      else
        FixtureAdapter.execute(command, ctx, runtime)
      end
    end

    def execute(command, ctx, runtime), do: FixtureAdapter.execute(command, ctx, runtime)
  end

  @max_commands 8
  @branching [
    branch_probability: 1.0,
    min_prefix_length: 1,
    max_branches: 2,
    max_branch_length: 2
  ]

  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  # MakeThing and Tick roots after the standard setup commands. The teardown
  # command names the fixture user: a run that fails part way through still
  # resolves it, where a thing a later root would have made is never made.
  defp things_model(name, checks \\ [TwoThings]) do
    model!(name,
      commands: [MakeThing, Tick],
      checks: checks,
      setup: SetupCommands.standard_setup(),
      teardown: [{Cleanup, overrides: fn state -> %{thing_id: state.user} end}]
    )
  end

  defp generate(model, seed, opts) do
    model
    |> Generator.generate_sequence(Keyword.merge([max_commands: @max_commands], opts))
    |> Generator.generate_value(seed)
  end

  defp find_seed(model, opts, predicate) do
    Enum.find(1..5_000, fn seed -> predicate.(generate(model, seed, opts)) end) ||
      flunk("no seed satisfies the fixture predicate")
  end

  defp count(commands, module), do: Enum.count(commands, &(&1.__struct__ == module))

  # A branching sequence that makes two things or more.
  defp failing_branching_seed(model) do
    find_seed(model, [branching: @branching], fn sequence ->
      Sequence.branching?(sequence) and count(Sequence.to_list(sequence), MakeThing) >= 2
    end)
  end

  defp run(model, targets, extra) do
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

  # The recorder entries of target `name`, one list per execution: each starts
  # at its `setup/1` and ends at its `teardown/1`.
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

  # Every execution ran the two setup commands first and the teardown command
  # last, the teardown command with the id the setup commands produced.
  defp assert_framed(executions) do
    assert executions != []

    for execution <- executions do
      commands = executed_in(execution)
      assert [%CreateUser{name: "fixture"}, %Login{} | _] = commands

      assert %Cleanup{thing_id: "a-u1"} = List.last(commands),
             "no teardown command in #{inspect(commands)}"
    end
  end

  # ==========================================================================
  # Branching runs (one target)
  # ==========================================================================

  describe "a branching sequence through Executor.run/4" do
    setup do
      user = Placeholder.new_at(UserCreated, [:id], Position.setup(0), 0)

      sequence =
        Sequence.with_registry(
          %Sequence{
            prefix: [%Act{n: 0, user_id: user}],
            branches: [[%Act{n: 1}], [%Act{n: 2}]],
            suffix: [%Act{n: 3}]
          },
          PlaceholderRegistry.register(PlaceholderRegistry.new(), user)
        )

      model = NoSimulatorModel

      opts = [
        setup_commands: [%CreateUser{name: "fixture"}, %Login{user_id: user}],
        teardown_commands: [%Cleanup{thing_id: nil}]
      ]

      {:ok, sequence: sequence, model: model, opts: opts}
    end

    test "runs the setup commands before the prefix and the teardown commands after the suffix and the :teardown checks",
         ctx do
      recorder = start_recorder()
      config = %{name: "a", recorder: recorder}

      assert {:ok, result} =
               Executor.run(
                 ctx.sequence,
                 ctx.model,
                 SetupCommands.FixtureAdapter,
                 [config: config] ++ ctx.opts
               )

      assert result.success

      assert recorded(recorder) == [
               {:setup, "a"},
               {:execute, "a", %CreateUser{name: "fixture"}},
               {:execute, "a", %Login{user_id: "a-u1"}},
               {:execute, "a", %Act{n: 0, user_id: "a-u1"}},
               {:execute, "a", %Act{n: 1}},
               {:execute, "a", %Act{n: 2}},
               {:execute, "a", %Act{n: 3}},
               {:teardown_check, "a"},
               {:execute, "a", %Cleanup{thing_id: nil}},
               {:teardown, "a"}
             ]

      phases = Enum.map(result.event_log, & &1.phase)
      assert List.first(phases) == :setup
      assert List.last(phases) == :teardown
    end

    test "a setup failure is a setup failure with no root index, and the teardown commands still run",
         ctx do
      recorder = start_recorder()
      config = %{name: "a", recorder: recorder, fail: %{Login => :error}}

      assert {:ok, result} =
               Executor.run(
                 ctx.sequence,
                 ctx.model,
                 SetupCommands.FixtureAdapter,
                 [config: config] ++ ctx.opts
               )

      refute result.success
      assert result.failed_at_index == nil
      assert Failure.kind(result.failure_reason) == :setup_failed

      assert %Failure.Setup{cause: :command, setup_index: 1, command: %Login{}} =
               result.failure_reason.type

      assert recorded(recorder) == [
               {:setup, "a"},
               {:execute, "a", %CreateUser{name: "fixture"}},
               {:execute, "a", %Login{user_id: "a-u1"}},
               {:execute, "a", %Cleanup{thing_id: nil}},
               {:teardown, "a"}
             ]
    end
  end

  describe "PropertyDamage.run/1 with branching:" do
    test "the run and the reproduction execute the setup and teardown commands" do
      recorder = start_recorder()
      model = things_model(BranchingRun)
      seed = failing_branching_seed(model)

      assert {:error, %FailureReport{} = report} =
               run(model, [SetupCommands.target("a", recorder)],
                 seed: seed,
                 branching: @branching,
                 shrink: false
               )

      assert report.kind == :check_failed
      executions = executions(recorded(recorder), "a")
      # The exploration run and the reproduction.
      assert length(executions) == 2
      assert_framed(executions)
      assert report.setup_commands == Sequence.setup_commands(report.original_sequence)
      assert [%Cleanup{}] = report.teardown_commands
    end

    test "a passing run counts the setup and teardown commands in its stats" do
      model = things_model(BranchingStats, [])

      assert {:ok, stats} =
               run(model, [SetupCommands.target("a", nil)],
                 seed: 11,
                 branching: @branching,
                 max_runs: 3
               )

      assert stats.setup_commands == 6
      assert stats.teardown_commands == 3
    end
  end

  describe "a branching shrink attempt" do
    test "executes the setup commands and a redrawn teardown, and a setup failure is never accepted" do
      recorder = start_recorder()
      model = things_model(BranchingShrink)
      seed = failing_branching_seed(model)
      sequence = generate(model, seed, branching: @branching)
      sequence = Generator.teardown_commands(model, sequence, seed)

      # The first attempt (the conversion to a linear sequence) fails its
      # Login, so the shrink goes on with the branching strategies.
      target =
        {FlakyLoginAdapter,
         name: "a",
         config: %{name: "a", recorder: recorder, logins: :counters.new(1, []), fail_login: 1}}

      capture_log(fn ->
        result =
          Shrinker.shrink(sequence,
            failed_at_index: nil,
            failure_reason:
              Failure.check_failed(:assert_fewer_than_two_things, "two things made"),
            model: model,
            targets: targets!([target]),
            rng_seed: seed
          )

        send(self(), {:result, result})
      end)

      assert_received {:result, result}
      executions = executions(recorded(recorder), "a")
      assert result.iterations > 1
      assert length(executions) == result.iterations
      assert_framed(executions)

      # The rejected conversion left the sequence branching.
      assert Sequence.branching?(result.sequence)
      assert Sequence.setup_commands(result.sequence) == Sequence.setup_commands(sequence)
      assert [%Cleanup{}] = Sequence.teardown_commands(result.sequence)
    end
  end

  describe "the seed-library replay of a branching run" do
    test "executes the setup and teardown commands" do
      recorder = start_recorder()
      model = things_model(BranchingReplay)
      seed = failing_branching_seed(model)

      path =
        Path.join(System.tmp_dir!(), "pd_setup_replay_#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)
      {:ok, library} = SeedLibrary.add_seed(SeedLibrary.new(), seed, model: "M")
      :ok = SeedLibrary.save(library, path)

      capture_io_and_log(fn ->
        assert {:error, %FailureReport{seed: ^seed}} =
                 run(model, [SetupCommands.target("a", recorder)],
                   seed: seed + 1,
                   branching: @branching,
                   shrink: false,
                   seed_library: path
                 )
      end)

      executions = executions(recorded(recorder), "a")
      # The replay and the reproduction.
      assert length(executions) == 2
      assert_framed(executions)
    end
  end

  # ==========================================================================
  # Report-driven and trace paths
  # ==========================================================================

  describe "RunTrace.capture/1" do
    test "executes the setup commands generated from its seed and the teardown commands" do
      recorder = start_recorder()
      model = things_model(Capture, [])

      trace =
        RunTrace.capture(
          model: model,
          targets: [SetupCommands.target("a", recorder)],
          seed: 5,
          max_commands: @max_commands
        )

      assert [execution] = executions(recorded(recorder), "a")
      assert_framed([execution])

      assert [%CreateUser{name: "fixture"}, %Login{}] = Sequence.setup_commands(trace.plan)
      assert [%Cleanup{}] = Sequence.teardown_commands(trace.plan)
      assert trace.outcome == :pass
    end
  end

  describe "Analysis.isolate_trigger/2" do
    test "runs every variation with the setup and teardown commands, valid from the post-setup state" do
      recorder = start_recorder()

      model =
        model!(Isolate,
          commands: SetupCommands.act_roots(),
          checks: [SecondActFails],
          setup: SetupCommands.standard_setup(),
          teardown: [{Cleanup, overrides: fn state -> %{thing_id: state.user} end}]
        )

      assert {:error, %FailureReport{} = report} =
               run(model, [SetupCommands.target("a", recorder)], seed: 1, shrink: false)

      assert report.kind == :check_failed
      before = length(executions(recorded(recorder), "a"))

      assert {:ok, isolation} = Analysis.isolate_trigger(report)

      assert Enum.any?(isolation.changes, &(&1.field == :n and &1.fixed == 0))

      variations = recorded(recorder) |> executions("a") |> Enum.drop(before)
      assert variations != []
      assert_framed(variations)

      # The roots consumed the id the setup commands produced.
      for execution <- variations,
          %Act{user_id: user_id} <- executed_in(execution) do
        assert user_id == "a-u1"
      end
    end
  end

  # ==========================================================================
  # Checks that fail on a setup command's event
  # ==========================================================================

  describe "an @eventually window a setup command opened" do
    test "that expires during the roots is a setup failure of that setup command" do
      model =
        model!(Eventually,
          checks: [LoginNeverSettles],
          setup: SetupCommands.standard_setup()
        )

      seed = find_seed(model, [], &(length(Sequence.to_list(&1)) >= 3))

      assert {:error, %FailureReport{} = report} =
               run(model, [{SlowAdapter, name: "a", config: %{name: "a"}}], seed: seed)

      assert report.kind == :setup_failed
      assert report.failed_at_index == nil

      assert %Failure.Setup{cause: :check, setup_index: 1, command: %Login{}} =
               report.failure_reason.type
    end

    test "is a setup failure of that setup command on a branching run" do
      model =
        model!(EventuallyBranching,
          checks: [LoginNeverSettles],
          setup: SetupCommands.standard_setup()
        )

      user = Placeholder.new_at(UserCreated, [:id], Position.setup(0), 0)

      sequence =
        Sequence.with_registry(
          %Sequence{
            prefix: [%Act{n: 0}],
            branches: [[%Act{n: 1}], [%Act{n: 2}]],
            suffix: [%Act{n: 3}]
          },
          PlaceholderRegistry.register(PlaceholderRegistry.new(), user)
        )

      assert {:ok, result} =
               Executor.run(sequence, model, SlowAdapter,
                 config: %{name: "a"},
                 setup_commands: [%CreateUser{name: "fixture"}, %Login{user_id: user}]
               )

      refute result.success
      assert result.failed_at_index == nil

      assert %Failure.Setup{cause: :check, setup_index: 1, command: %Login{}} =
               result.failure_reason.type
    end
  end

  describe "check_mode: :record" do
    test "reports a check that failed on a setup command's event as a setup failure, and setup commands do not advance every: N" do
      :persistent_term.put({__MODULE__, :every3}, self())
      on_exit(fn -> :persistent_term.erase({__MODULE__, :every3}) end)

      model =
        model!(Recorded,
          commands: [Tick],
          checks: [SetupCommands.LoginCheck, EveryThirdRoot],
          setup: SetupCommands.standard_setup()
        )

      seed = find_seed(model, [], &(count(Sequence.to_list(&1), Tick) >= 6))
      ticks = model |> generate(seed, []) |> Sequence.to_list() |> count(Tick)

      assert {:error, %FailureReport{} = report} =
               run(model, [{SetupCommands.FixtureAdapter, name: "a", config: %{name: "a"}}],
                 seed: seed,
                 check_mode: :record,
                 shrink: false
               )

      assert report.kind == :setup_failed

      assert %Failure.Setup{cause: :check, setup_index: 1, command: %Login{}} =
               report.failure_reason.type

      # Tick has no events: every third Tick fires the check, counted from the
      # first root.
      fired = for {:every3, n} <- take_messages(:every3), do: n
      assert fired == Enum.filter(1..ticks, &(rem(&1, 3) == 0))
    end
  end

  defp capture_io_and_log(fun) do
    capture_log(fn -> ExUnit.CaptureIO.capture_io(fun) end)
  end
end
