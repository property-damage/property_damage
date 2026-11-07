defmodule PropertyDamage.SetupCommandsPathsTest do
  # Every path that executes a run's sequence again runs its setup commands
  # before the roots and its teardown commands after them:
  # `PropertyDamage.replay/2`, `RunTrace.Capture.capture/1` and
  # `Analysis.isolate_trigger/2`. A check failure that belongs to a setup
  # command is a setup failure on every path.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{
    Analysis,
    Failure,
    FailureReport,
    Generator,
    RunTrace,
    Sequence
  }

  alias PropertyDamage.Test.SetupCommands

  alias PropertyDamage.Test.SetupCommands.{
    Act,
    Cleanup,
    CreateUser,
    Login,
    MakeThing,
    Tick
  }

  # ==========================================================================
  # Fixtures
  # ==========================================================================

  defmodule SecondActFails do
    # Fails on the event of the Act whose `n` is 1 (the second Act root).
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.SetupCommands.Acted
    def assert_not_second_act(_state, %{n: n}) do
      n != 1 or PropertyDamage.fail!("the second act")
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

  @max_commands 8
  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  # MakeThing and Tick roots after the standard setup commands. The teardown
  # command names the fixture user: a run that fails part way through still
  # resolves it, where a thing a later root would have made is never made.
  defp things_model(name, checks) do
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
  # Report-driven and trace paths
  # ==========================================================================

  describe "RunTrace.Capture.capture/1" do
    test "executes the setup commands generated from its seed and the teardown commands" do
      recorder = start_recorder()
      model = things_model(Capture, [])

      trace =
        RunTrace.Capture.capture(
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

  describe "Analysis.isolate_trigger/2 changes" do
    test "never repeat a {field, fixed} pair" do
      model =
        model!(IsolateDistinct,
          commands: SetupCommands.act_roots(),
          checks: [SecondActFails],
          setup: SetupCommands.standard_setup(),
          teardown: [{Cleanup, overrides: fn state -> %{thing_id: state.user} end}]
        )

      assert {:error, %FailureReport{} = report} =
               run(model, [SetupCommands.target("a", start_recorder())], seed: 1, shrink: false)

      assert {:ok, isolation} = Analysis.isolate_trigger(report)

      pairs = Enum.map(isolation.changes, &{&1.field, &1.fixed})
      assert pairs != []
      assert pairs == Enum.uniq(pairs)
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
end
