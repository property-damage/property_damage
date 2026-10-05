defmodule PropertyDamage.DifferentialRunTest do
  # `Differential.run/1` runs every run through the lockstep scheduler: each
  # target is a variant in its own process, set up and torn down per run, and
  # compared root by root.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Differential, Failure, Generator, Sequence}
  alias PropertyDamage.Differential.{Equivalence, Result}

  alias PropertyDamage.Test.Lockstep.{
    CountingMock,
    GuardedStepModel,
    Noted,
    NoteInjector,
    PolledModel,
    ProbeAdapter,
    Probed,
    ProbeModel,
    StartupModel,
    Step,
    StepAdapter,
    StepModel,
    Stepped
  }

  @seed 12_345

  @metric_keys [
    :error_count,
    :error_rate,
    :latency_max,
    :latency_mean,
    :latency_min,
    :latency_p50,
    :latency_p95,
    :latency_p99,
    :total_commands
  ]

  defp step(name, config \\ %{}, entry \\ []) do
    {StepAdapter, [name: name, config: Map.merge(%{name: name}, config)] ++ entry}
  end

  defp run!(targets, extra \\ []) do
    {:ok, result} =
      Differential.run(
        Keyword.merge(
          [
            model: StepModel,
            targets: targets,
            compare: :correctness,
            max_runs: 1,
            max_commands: 3,
            seed: @seed
          ],
          extra
        )
      )

    result
  end

  # The command list run `run_number` of a campaign generates, exactly as the
  # caller would derive it.
  defp generated(model, seed, run_number, max_commands) do
    model
    |> Generator.generate_sequence(max_commands: max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, run_number))
    |> Sequence.to_list()
  end

  defp entered(recorder, name) do
    for {:enter, ^name, index} <- recorded(recorder), do: index
  end

  describe "options" do
    test "concurrency defaults to :serial" do
      result = run!([step("a"), step("b")])

      assert result.status == :equivalent
      assert Map.get(result, :concurrency) == :serial
    end

    test "concurrency: :parallel is accepted and reported" do
      result = run!([step("a"), step("b")], concurrency: :parallel)

      assert result.status == :equivalent
      assert Map.get(result, :concurrency) == :parallel
    end

    test "concurrency: :serial is accepted and any other value is rejected" do
      assert Map.get(run!([step("a"), step("b")], concurrency: :serial), :concurrency) == :serial

      assert_raise NimbleOptions.ValidationError, fn ->
        run!([step("a"), step("b")], concurrency: :interleaved)
      end
    end

    for mode <- [:interleaved, :sequential] do
      test "execution: #{inspect(mode)} is an option error that names concurrency:" do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            run!([step("a"), step("b")], execution: unquote(mode))
          end

        # A message written for the removed key, not NimbleOptions' generic
        # list of valid keys (which would name concurrency anyway).
        assert error.message =~ "`execution:`"
        assert error.message =~ "`concurrency:`"
      end
    end

    for compare <- [:performance, :both] do
      test "compare: #{inspect(compare)} with concurrency: :parallel is an option error" do
        # The same comparison mode runs under :serial.
        assert %Result{} =
                 run!([step("a"), step("b")], compare: unquote(compare), concurrency: :serial)

        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            run!([step("a"), step("b")], compare: unquote(compare), concurrency: :parallel)
          end

        assert error.message =~ "concurrency"
      end
    end

    test "the result reports concurrency and failure, and no longer an execution mode" do
      keys = Result |> struct() |> Map.keys()

      assert :concurrency in keys
      assert :failure in keys
      refute :execution in keys
    end

    test "per-target injectors and mocks are accepted and set up per run" do
      mock = {CountingMock, %{name: "mock", test_pid: self()}}

      result =
        run!(
          [step("a"), step("b", %{}, injectors: [NoteInjector], mocks: [mock])],
          max_runs: 3
        )

      assert result.status == :equivalent
      assert length(take_messages(:mock_setup)) == 3
    end
  end

  describe "root observations and divergences" do
    test "a divergence names the root, the variant and both observations, injected events first" do
      result = run!([step("a", %{behavior: :inject}), step("b", %{behavior: :inject_shift})])

      assert result.status == :divergent
      assert [divergence] = result.divergences

      assert divergence |> Map.keys() |> Enum.sort() ==
               [
                 :command,
                 :divergent_result,
                 :reference_result,
                 :results,
                 :root,
                 :run,
                 :seed,
                 :variant
               ]

      assert %Step{value: value} = divergence.command
      assert divergence.seed == @seed
      assert divergence.run == 0
      assert divergence.root == 0
      assert divergence.variant == %{index: 1, name: "b"}

      assert divergence.reference_result == {:ok, [%Noted{value: value}, %Stepped{value: value}]}

      assert divergence.divergent_result ==
               {:ok, [%Noted{value: value}, %Stepped{value: value + 1}]}

      assert divergence.results == %{
               "a" => divergence.reference_result,
               "b" => divergence.divergent_result
             }
    end

    test "a divergence after root 0 names that root and its command" do
      result = run!([step("a"), step("b", %{bad_at: 1})], max_commands: 3)

      assert [divergence] = result.divergences
      assert divergence.root == 1
      assert divergence.command == Enum.at(generated(StepModel, @seed, 0, 3), 1)
      assert {:ok, [%Stepped{mark: :bad}]} = divergence.divergent_result
    end

    test "an adapter {:error, reason} is observed as {:error, reason}" do
      result = run!([step("a"), step("b", %{behavior: :error})])

      assert [divergence] = result.divergences
      assert {:ok, [%Stepped{}]} = divergence.reference_result
      assert divergence.divergent_result == {:error, :refused}
    end

    test ":exact compares whole observations and :structural ignores identifiers" do
      targets = [step("a"), step("b", %{behavior: :new_id})]

      assert run!(targets, equivalence: :exact).status == :divergent
      assert run!(targets, equivalence: :structural).status == :equivalent
    end

    test "a custom equivalence function receives the two observations" do
      targets = [step("a"), step("b", %{behavior: :shift})]

      close_enough = fn {:ok, [%Stepped{value: x}]}, {:ok, [%Stepped{value: y}]} ->
        abs(x - y) <= 1
      end

      assert run!(targets, equivalence: close_enough).status == :equivalent
      assert run!(targets, equivalence: fn _, _ -> false end).status == :divergent
    end

    test "divergences are listed oldest first and each run stops at its first divergence" do
      recorder = start_recorder()
      result = run!([step("a"), step("b", %{behavior: :shift, recorder: recorder})], max_runs: 4)

      assert result.status == :divergent
      assert Enum.map(result.divergences, & &1.run) == [0, 1, 2, 3]
      assert Enum.all?(result.divergences, &(&1.root == 0))
      assert entered(recorder, "b") == [0, 0, 0, 0]
    end

    test "a probe root that retries before settling is compared on its settled events" do
      targets = [
        {ProbeAdapter, name: "a", config: %{retries: 2}},
        {ProbeAdapter, name: "b", config: %{retries: 2}}
      ]

      equal = run!(targets, model: ProbeModel, max_runs: 2)
      assert equal.status == :equivalent
      assert Map.get(equal, :failure) == nil

      shifted =
        run!(
          [
            {ProbeAdapter, name: "a", config: %{retries: 2}},
            {ProbeAdapter, name: "b", config: %{retries: 1, offset: 1}}
          ],
          model: ProbeModel
        )

      assert [divergence] = shifted.divergences
      assert {:ok, [%Probed{value: value}]} = divergence.reference_result
      assert divergence.divergent_result == {:ok, [%Probed{value: value + 1}]}
    end
  end

  describe "failures" do
    test "an adapter raise in one variant is an execution failure naming it, never a divergence" do
      result = run!([step("a"), step("b", %{behavior: :raise})])

      assert result.status == :failed
      assert result.divergences == []

      failure = Map.get(result, :failure)
      assert failure |> Map.keys() |> Enum.sort() == [:kind, :reason, :root, :run, :variant]
      assert failure.kind == :execution_failed
      assert failure.variant == %{index: 1, name: "b"}
      assert failure.run == 0
      assert failure.root == 0
      assert %RuntimeError{message: "candidate exploded"} = failure.reason
    end

    test "a check failure in the non-reference variant is a failure, and later variants of that root do not run" do
      recorder = start_recorder()

      result =
        run!(
          [
            step("a", %{recorder: recorder}),
            step("b", %{recorder: recorder, bad_at: 1}),
            step("c", %{recorder: recorder})
          ],
          model: GuardedStepModel,
          equivalence: Equivalence.ignore_fields([:mark])
        )

      assert result.status == :failed
      assert result.divergences == []

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, run: 0, root: 1} =
               Map.get(result, :failure)

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} =
               Map.get(result, :failure).reason

      assert entered(recorder, "a") == [0, 1]
      assert entered(recorder, "b") == [0, 1]
      assert entered(recorder, "c") == [0]
    end

    test "under :parallel a check failure stops the run before the next root starts" do
      recorder = start_recorder()

      result =
        run!(
          [
            step("a", %{recorder: recorder}),
            step("b", %{recorder: recorder, bad_at: 1}),
            step("c", %{recorder: recorder})
          ],
          model: GuardedStepModel,
          equivalence: Equivalence.ignore_fields([:mark]),
          concurrency: :parallel
        )

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, root: 1} =
               Map.get(result, :failure)

      assert result.divergences == []

      for name <- ["a", "b", "c"] do
        assert Enum.all?(entered(recorder, name), &(&1 <= 1))
      end
    end

    test "a :startup check that fails in one variant names it, with no root" do
      result = run!([step("a"), step("b", %{fail_startup: true})], model: StartupModel)

      assert result.status == :failed

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, run: 0, root: nil} =
               Map.get(result, :failure)

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :ready}} =
               Map.get(result, :failure).reason
    end

    test "a failure ends the campaign and keeps the divergences of earlier runs" do
      {:ok, counter} = Agent.start_link(fn -> %{} end)

      result =
        run!(
          [
            step("a", %{counter: counter}),
            step("b", %{counter: counter, behavior: :shift, raise_on_run: 2})
          ],
          max_runs: 5
        )

      assert result.status == :failed
      assert Enum.map(result.divergences, & &1.run) == [0, 1]
      assert %{kind: :execution_failed, run: 2, variant: %{index: 1}} = Map.get(result, :failure)

      # No run after the failing one was started.
      assert Agent.get(counter, & &1) == %{"a" => 3, "b" => 3}
    end
  end

  describe "pollers inside a multi-target run" do
    test "an adapter may start a resource poller and its events reach that variant" do
      result =
        run!(
          [step("a", %{poll: :deliver}), step("b", %{poll: :deliver})],
          model: PolledModel,
          max_runs: 2
        )

      # PolledModel's @eventually check passes only when every step's value was
      # delivered back by that variant's resource poller.
      assert result.status == :equivalent
      assert Map.get(result, :failure) == nil
    end

    test "a variant whose poller never delivers fails its @eventually check (control)" do
      result =
        run!(
          [step("a", %{poll: :deliver}), step("b", %{poll: :never})],
          model: PolledModel
        )

      assert result.status == :failed
      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}} = Map.get(result, :failure)
    end
  end

  describe "performance comparison" do
    test "reports today's latency metrics per target and excludes warm-up runs" do
      result =
        run!([step("fast"), step("broken", %{behavior: :error})],
          compare: :performance,
          max_runs: 3,
          warmup_runs: 1
        )

      assert Map.get(result, :concurrency) == :serial
      assert result.metrics |> Map.keys() |> Enum.sort() == ["broken", "fast"]

      measured =
        Enum.sum(for run <- 1..2, do: length(generated(StepModel, @seed, run, 3)))

      for name <- ["fast", "broken"] do
        metrics = result.metrics[name]
        assert metrics |> Map.keys() |> Enum.sort() == @metric_keys
        assert metrics.total_commands == measured
      end

      assert result.metrics["fast"].error_count == 0
      assert result.metrics["broken"].error_count == measured
      assert result.metrics["broken"].error_rate == 1.0
    end
  end

  describe "per-run setup" do
    test "every target is set up and torn down once per run, in its own process, setups in target order" do
      recorder = start_recorder()
      config = %{test_pid: self(), recorder: recorder, setup_delay_ms: 20}

      result = run!([step("a", config), step("b", config)], max_runs: 3, max_commands: 2)
      assert result.status == :equivalent

      setups = take_messages(:setup)
      teardowns = take_messages(:teardown)

      for name <- ["a", "b"] do
        setup_pids = for {:setup, ^name, pid} <- setups, do: pid
        teardown_pids = for {:teardown, ^name, pid} <- teardowns, do: pid

        assert length(setup_pids) == 3
        assert teardown_pids == setup_pids
        refute self() in setup_pids
      end

      pids_a = for {:setup, "a", pid} <- setups, do: pid
      pids_b = for {:setup, "b", pid} <- setups, do: pid
      assert MapSet.disjoint?(MapSet.new(pids_a), MapSet.new(pids_b))

      setup_order =
        for {tag, name} <- recorded(recorder), tag in [:setup, :setup_done], do: {tag, name}

      assert setup_order ==
               List.flatten(
                 List.duplicate(
                   [{:setup, "a"}, {:setup_done, "a"}, {:setup, "b"}, {:setup_done, "b"}],
                   3
                 )
               )
    end

    test "no variant executes command 0 before every variant's setup returned" do
      config = %{test_pid: self(), hold_setup: true}
      test_pid = self()

      task =
        Task.async(fn ->
          result = run!([step("a", config), step("b", config)])
          send(test_pid, :run_returned)
          result
        end)

      assert_receive {:setup_waiting, "a", setup_a}, 2_000
      refute_receive {:setup_waiting, "b", _}, 100
      send(setup_a, :release_setup)

      assert_receive {:setup_waiting, "b", setup_b}, 2_000
      refute_receive {:executed, _, _, _}, 100
      send(setup_b, :release_setup)

      assert_receive {:executed, "a", 0, _}, 2_000
      assert %Result{status: :equivalent} = Task.await(task, 5_000)
    end

    test "a setup error in variant 1 is a setup failure; variant 0 is torn down" do
      result =
        run!([step("a", %{test_pid: self()}), step("b", %{setup_result: :error})], max_runs: 3)

      assert result.status == :failed
      assert result.divergences == []

      assert %{kind: :setup_failed, variant: %{index: 1, name: "b"}, run: 0, root: nil} =
               Map.get(result, :failure)

      assert [{:setup, "a", setup_a}] = take_messages(:setup)
      assert [{:teardown, "a", ^setup_a}] = take_messages(:teardown)
    end

    test "a raising setup in variant 1 is a setup failure; variant 0 is torn down" do
      result = run!([step("a", %{test_pid: self()}), step("b", %{setup_result: :raise})])

      assert result.status == :failed

      assert %{kind: :setup_failed, variant: %{index: 1, name: "b"}, root: nil} =
               Map.get(result, :failure)

      assert [{:setup, "a", setup_a}] = take_messages(:setup)
      assert [{:teardown, "a", ^setup_a}] = take_messages(:teardown)
    end

    test "setup draws from a per-variant RNG seeded from the run seed and the variant index" do
      seed = 777

      targets = [
        step("a", %{test_pid: self(), draw: true}),
        step("b", %{test_pid: self(), draw: true})
      ]

      run!(targets, seed: seed, max_runs: 2)
      first = take_messages(:drawn)
      run!(targets, seed: seed, max_runs: 2)
      second = take_messages(:drawn)

      expected =
        for run_number <- 0..1, {name, index} <- [{"a", 0}, {"b", 1}] do
          {:drawn, name, expected_draw(seed, run_number, index)}
        end

      assert first == expected
      assert second == expected
    end
  end

  describe "formatting" do
    test "divergent and failed results format without error" do
      divergent = run!([step("a"), step("b", %{behavior: :shift})])
      assert is_binary(Result.format(divergent, format: :full))

      failed = run!([step("a"), step("b", %{behavior: :raise})])
      assert is_binary(Result.format(failed, format: :full))
    end
  end

  defp expected_draw(seed, run_number, index) do
    state =
      :rand.seed_s(
        :exsss,
        :erlang.phash2({Generator.run_seed(seed, run_number), index}, 4_294_967_296)
      )

    {value, _state} = :rand.uniform_s(1_000_000_000, state)
    value
  end
end
