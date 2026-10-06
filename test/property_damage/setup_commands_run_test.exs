defmodule PropertyDamage.SetupCommandsRunTest do
  # Setup commands run in every target after `Adapter.setup/1` and before root
  # 0, through the engine; teardown commands run after the final boundary and
  # the `:teardown` checks and before `Adapter.teardown/1`.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Failure, FailureReport, Sequence}
  alias PropertyDamage.Test.SetupCommands

  alias PropertyDamage.Test.SetupCommands.{
    Act,
    Cleanup,
    CreateUser,
    Fixture,
    Login,
    LoginCheck,
    LoginCompare,
    MakeThing,
    Noted,
    Tick
  }

  @seed 4_242

  defp model!(name, opts), do: SetupCommands.define_model!(Module.concat(__MODULE__, name), opts)

  defp run(model, targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 3,
          seed: @seed,
          shrink: false,
          validate: false
        ],
        extra
      )
    )
  end

  defp standard_model(name, extra \\ []) do
    model!(name, Keyword.merge([setup: SetupCommands.standard_setup()], extra))
  end

  # Each setup command executed at least once in `name`.
  defp assert_setup_ran(entries, name) do
    executed = SetupCommands.executed(entries, name)
    assert Enum.any?(executed, &match?(%CreateUser{}, &1))
    assert Enum.any?(executed, &match?(%Login{}, &1))
  end

  describe "setup commands in a two-target run" do
    test "run per target after setup/1 and before the roots, with that target's ids" do
      recorder = start_recorder()
      model = standard_model(TwoTargets)

      assert {:ok, %{total_commands: 3}} =
               run(model, [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder)
               ])

      entries = recorded(recorder)

      for name <- ["a", "b"] do
        assert [
                 {:setup, ^name},
                 {:execute, ^name, %CreateUser{name: "fixture"}},
                 {:execute, ^name, %Login{user_id: user_id}},
                 {:execute, ^name, %Act{n: 0, user_id: user_id}} | _
               ] = SetupCommands.of(entries, name)

        # The id this target's CreateUser returned, resolved per target.
        assert user_id == "#{name}-u1"
      end
    end

    test "a single-target run executes them once per run" do
      recorder = start_recorder()
      model = standard_model(OneTarget)

      assert {:ok, stats} = run(model, [SetupCommands.target("a", recorder)], max_runs: 3)

      executed = SetupCommands.executed(recorded(recorder), "a")
      assert Enum.count(executed, &match?(%CreateUser{}, &1)) == 3
      assert Enum.count(executed, &match?(%Login{}, &1)) == 3
      assert stats.setup_commands == 6
      assert stats.teardown_commands == 0
      assert stats.total_commands == 9
    end
  end

  describe "teardown commands" do
    defp teardown_model(name, extra \\ []) do
      model!(
        name,
        Keyword.merge(
          [
            commands: [MakeThing],
            setup: SetupCommands.standard_setup(),
            teardown: [{Cleanup, overrides: fn state -> %{thing_id: List.last(state.things)} end}]
          ],
          extra
        )
      )
    end

    test "run after the final boundary and the :teardown checks, before teardown/1" do
      recorder = start_recorder()
      model = teardown_model(Order)

      assert {:ok, stats} =
               run(model, [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder)
               ])

      assert stats.teardown_commands == 1
      entries = recorded(recorder)
      assert_setup_ran(entries, "a")

      for name <- ["a", "b"] do
        mine = SetupCommands.of(entries, name)

        last_compared =
          mine
          |> Enum.with_index()
          |> Enum.filter(&match?({{:compared, _, _}, _}, &1))
          |> List.last()
          |> elem(1)

        check = SetupCommands.position(mine, &(&1 == {:teardown_check, name}))
        cleanup = SetupCommands.position(mine, &match?({:execute, _, %Cleanup{}}, &1))
        teardown = SetupCommands.position(mine, &(&1 == {:teardown, name}))

        assert last_compared < cleanup
        assert check < cleanup
        assert cleanup < teardown

        # The cleanup names the id the last root returned in this target: the
        # adapter numbers every id it mints (the user, then three things).
        assert {:execute, ^name, %Cleanup{thing_id: thing_id}} = Enum.at(mine, cleanup)
        assert thing_id == "#{name}-t4"
      end
    end

    for {label, config} <- [
          divergence: %{mode: :shift},
          not_converging: %{mode: :pending},
          root_error_in_reference: %{fail: %{Act => :error}}
        ] do
      test "run after a #{label}" do
        recorder = start_recorder()
        model = model!(Module.concat(After, unquote(label)), teardown_like_act())

        {config_a, config_b} =
          case unquote(label) do
            :root_error_in_reference -> {unquote(Macro.escape(config)), %{}}
            _ -> {%{}, unquote(Macro.escape(config))}
          end

        assert {:error, %FailureReport{}} =
                 run(model, [
                   SetupCommands.target("a", recorder, config_a),
                   SetupCommands.target("b", recorder, config_b)
                 ])

        entries = recorded(recorder)

        for name <- ["a", "b"] do
          mine = SetupCommands.of(entries, name)
          cleanup = SetupCommands.position(mine, &match?({:execute, _, %Cleanup{}}, &1))
          teardown = SetupCommands.position(mine, &(&1 == {:teardown, name}))
          assert is_integer(cleanup), "no teardown command ran in #{name}"
          assert cleanup < teardown
        end
      end
    end

    test "run in a retired variant before its teardown/1" do
      recorder = start_recorder()
      model = model!(Retired, teardown_like_act())

      assert {:error, %FailureReport{kind: :execution_failed, variant: %{index: 1}}} =
               run(model, [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder, %{fail: %{Act => :error}})
               ])

      mine = SetupCommands.of(recorded(recorder), "b")
      cleanup = SetupCommands.position(mine, &match?({:execute, _, %Cleanup{}}, &1))
      teardown = SetupCommands.position(mine, &(&1 == {:teardown, "b"}))
      assert is_integer(cleanup)
      assert cleanup < teardown
    end

    test "run after a setup failure" do
      recorder = start_recorder()
      model = model!(AfterSetupFailure, teardown_like_act())

      assert {:error, %FailureReport{kind: :setup_failed}} =
               run(model, [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder, %{fail: %{Login => :error}})
               ])

      for name <- ["a", "b"] do
        mine = SetupCommands.of(recorded(recorder), name)
        cleanup = SetupCommands.position(mine, &match?({:execute, _, %Cleanup{}}, &1))
        teardown = SetupCommands.position(mine, &(&1 == {:teardown, name}))
        assert is_integer(cleanup)
        assert cleanup < teardown
      end
    end

    test "an error is logged and leaves the run passing" do
      recorder = start_recorder()
      model = teardown_model(TeardownError)

      log =
        capture_log(fn ->
          assert {:ok, %{runs: 1}} =
                   run(model, [SetupCommands.target("a", recorder, %{fail: %{Cleanup => :error}})])
        end)

      assert log =~ "Cleanup"
      assert log =~ "\"a\""
      assert_setup_ran(recorded(recorder), "a")
    end

    test "their events are logged with phase :teardown and folded into no projection" do
      recorder = start_recorder()
      model = teardown_model(Logged)
      sequence = generated(model)
      targets = targets!([SetupCommands.target("a", recorder)])

      {:ok, outcome} =
        run_scheduler(
          model: model,
          targets: targets,
          commands: Sequence.to_list(sequence),
          setup_commands: Sequence.setup_commands(sequence),
          teardown_commands: Sequence.teardown_commands(sequence),
          placeholder_registry: sequence.registry,
          seed: @seed,
          run_number: 0,
          run_nonce: 1,
          concurrency: :serial
        )

      assert outcome.failure == nil
      [result] = outcome.results

      assert [%{phase: :teardown, command_index: 0, event: %Noted{}}] =
               Enum.filter(result.event_log, &(&1.phase == :teardown))

      assert [%{phase: :setup, command_index: 0}, %{phase: :setup, command_index: 1}] =
               Enum.filter(result.event_log, &(&1.phase == :setup))

      assert_setup_ran(recorded(recorder), "a")
      # Fixture raises on a folded Noted and fails a check on a checked one;
      # neither happened.
      refute Map.has_key?(result.check_counters, {:fired, Fixture, :no_teardown_event})
    end
  end

  # A model whose roots are Acts and whose teardown command is a Cleanup.
  defp teardown_like_act do
    [
      setup: SetupCommands.standard_setup(),
      teardown: [{Cleanup, overrides: fn _state -> %{thing_id: "none"} end}]
    ]
  end

  defp generated(model) do
    model
    |> PropertyDamage.Generator.generate_sequence(max_commands: 3)
    |> PropertyDamage.Generator.generate_value(@seed)
    |> then(&PropertyDamage.Generator.teardown_commands(model, &1, @seed))
  end

  describe "engine rules for setup commands" do
    test "a check on a setup command fails the run as a setup failure" do
      recorder = start_recorder()
      model = standard_model(CheckedLogin, checks: [Fixture, LoginCheck])

      assert {:error, %FailureReport{} = report} =
               run(model, [SetupCommands.target("a", recorder)])

      assert report.kind == :setup_failed
      assert report.failed_at_index == nil
      assert Failure.kind(report.failure_reason) == :setup_failed

      assert %Failure{type: %Failure.Setup{cause: :check, setup_index: 1, command: %Login{}}} =
               report.failure_reason

      assert_setup_ran(recorded(recorder), "a")
      assert for({:execute, "a", %Act{}} <- recorded(recorder), do: 1) == []
    end

    @tag :every_n
    test "an every: 3 check is not advanced by setup commands" do
      :persistent_term.put({SetupCommands, :every3}, self())
      on_exit(fn -> :persistent_term.erase({SetupCommands, :every3}) end)

      plain = model!(EveryPlain, commands: [Tick], checks: [SetupCommands.EveryThird])

      with_setup =
        model!(EveryWithSetup,
          commands: [Tick],
          checks: [SetupCommands.EveryThird],
          setup: [CreateUser, Tick, Tick]
        )

      recorder = start_recorder()
      assert {:ok, _} = run(plain, [SetupCommands.target("a", recorder)], max_commands: 5)
      without = take_messages(:every3)

      assert {:ok, _} = run(with_setup, [SetupCommands.target("a", recorder)], max_commands: 5)
      with = take_messages(:every3)

      # Without setup commands the check fires at the third Tick root. With
      # them it fires at the same root: the two setup Ticks add to the count
      # it records, but not to the sampling counter.
      assert without == [{:every3, 3}]
      assert with == [{:every3, 5}]

      assert Enum.count(
               SetupCommands.executed(recorded(recorder), "a"),
               &match?(%CreateUser{}, &1)
             ) == 1
    end

    test "stutter does not retry a setup command" do
      recorder = start_recorder()
      model = standard_model(Stutter)

      assert {:ok, _} =
               run(model, [SetupCommands.target("a", recorder)],
                 stutter: [probability: 1.0, max_repeats: 1, delay_ms: 0]
               )

      executed = SetupCommands.executed(recorded(recorder), "a")
      assert Enum.count(executed, &match?(%CreateUser{}, &1)) == 1
      assert Enum.count(executed, &match?(%Login{}, &1)) == 1
      # The roots were retried, so stutter was on.
      assert Enum.count(executed, &match?(%Act{}, &1)) == 6
    end

    test "@compare every: 1 is compared at the roots only" do
      recorder = start_recorder()
      model = standard_model(CompareEvery)

      assert {:ok, stats} =
               run(model, [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder)
               ])

      assert stats.compare_counts[{Fixture, :acts}].compared_at == stats.total_commands
      assert_setup_ran(recorded(recorder), "b")
    end

    test "@compare every: Login never fires on a setup Login" do
      recorder = start_recorder()
      model = standard_model(CompareLogin, checks: [Fixture, LoginCompare])

      assert {:ok, stats} =
               run(model, [
                 SetupCommands.target("a", recorder),
                 SetupCommands.target("b", recorder)
               ])

      assert stats.compare_counts[{LoginCompare, :logins}].compared_at == 0
      assert_setup_ran(recorded(recorder), "a")
    end

    for {label, config} <- [missing_field: %{drop_id: true}, no_event: %{no_event: true}] do
      test "an external() that never arrives is an unresolved-placeholder setup failure (#{label})" do
        recorder = start_recorder()
        model = model!(Module.concat(Unresolved, unquote(label)), setup: [CreateUser])

        assert {:error, %FailureReport{} = report} =
                 run(model, [
                   SetupCommands.target("a", recorder),
                   SetupCommands.target("b", recorder, unquote(Macro.escape(config)))
                 ])

        assert report.kind == :setup_failed
        assert report.variant == %{index: 1, name: "b"}

        assert %Failure{
                 type: %Failure.Setup{
                   cause: :unresolved_placeholder,
                   field: [:id],
                   setup_index: 0,
                   command: %CreateUser{}
                 }
               } = report.failure_reason

        assert SetupCommands.executed(recorded(recorder), "b") |> Enum.filter(&match?(%Act{}, &1)) ==
                 []

        assert Enum.count(
                 SetupCommands.executed(recorded(recorder), "b"),
                 &match?(%CreateUser{}, &1)
               ) ==
                 1
      end
    end

    test "latency: true times the roots only" do
      recorder = start_recorder()
      model = standard_model(Latency, teardown: [{Cleanup, overrides: %{thing_id: "x"}}])

      assert {:ok, stats} =
               run(
                 model,
                 [
                   SetupCommands.target("a", recorder),
                   SetupCommands.target("b", recorder)
                 ],
                 latency: true
               )

      for name <- ["a", "b"] do
        assert stats.metrics[name].total_commands == stats.total_commands
      end

      assert_setup_ran(recorded(recorder), "a")
    end
  end
end
