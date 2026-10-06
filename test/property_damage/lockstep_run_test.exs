defmodule PropertyDamage.LockstepRunTest do
  # `PropertyDamage.run/1` runs every run through the lockstep scheduler: each
  # target is a variant in its own process, set up and torn down per run, and
  # compared root by root.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Failure, FailureReport, Generator, Sequence}

  alias PropertyDamage.Test.Lockstep.{
    CountingMock,
    GuardedStepModel,
    NoteInjector,
    PolledModel,
    ProbeAdapter,
    ProbeModel,
    StartupModel,
    Step,
    StepAdapter,
    StepModel
  }

  alias PropertyDamage.Test.Lockstep.Ledger

  @seed 12_345

  defmodule IdObservation do
    # Compares the ids every Stepped event carries.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.Lockstep.Stepped

    @impl true
    def init, do: []

    @impl true
    def apply(ids, %Stepped{id: id}), do: [id | ids]
    def apply(ids, _other), do: ids

    @compare every: 1
    def ids(ids, _root), do: ids
  end

  defmodule CloseValues do
    # Compares Stepped values, agreeing when they differ by at most one.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.Lockstep.Stepped

    @impl true
    def init, do: []

    @impl true
    def apply(values, %Stepped{value: v}), do: [v | values]
    def apply(values, _other), do: values

    @compare using: fn reference, variant ->
               Enum.zip(reference, variant) |> Enum.all?(fn {x, y} -> abs(x - y) <= 1 end)
             end
    def values(values, _root), do: values
  end

  defmodule NeverAgree do
    # A predicate that never accepts the variant's value.
    use PropertyDamage.Model.Projection

    @compare using: fn _reference, _variant -> false end
    def anything(_state, root), do: root
  end

  defmodule Finished do
    # Latency runs compare nothing a target's speed or errors change: one
    # observation at the end that every target agrees on.
    use PropertyDamage.Model.Projection

    @compare every: :end
    def finished(_state, _root), do: :finished
  end

  for {name, observation} <- [
        IdModel: IdObservation,
        CloseModel: CloseValues,
        NeverModel: NeverAgree,
        LatencyModel: Finished
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      @behaviour PropertyDamage.Model

      @impl true
      def commands, do: [PropertyDamage.Test.Lockstep.Step]

      @impl true
      def command_sequence_projection, do: Ledger

      @impl true
      def check_projections, do: [unquote(observation)]
    end
  end

  @metric_keys [:by_command, :commands, :max, :mean, :min, :p50, :p95, :p99]

  defp step(name, config \\ %{}, entry \\ []) do
    {StepAdapter, [name: name, config: Map.merge(%{name: name}, config)] ++ entry}
  end

  defp run!(targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: StepModel,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 3,
          seed: @seed,
          validate: false
        ],
        extra
      )
    )
  end

  defp failure!(targets, extra \\ []) do
    assert {:error, %FailureReport{} = report} = run!(targets, extra)
    report
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
    test "concurrency defaults to :serial: one target at a time, in target order" do
      recorder = start_recorder()

      assert {:ok, _stats} =
               run!([step("a", %{recorder: recorder}), step("b", %{recorder: recorder})])

      calls =
        for {tag, name, index} <- recorded(recorder),
            tag in [:enter, :exit],
            do: {tag, name, index}

      assert calls ==
               Enum.flat_map(0..(div(length(calls), 4) - 1)//1, fn index ->
                 [
                   {:enter, "a", index},
                   {:exit, "a", index},
                   {:enter, "b", index},
                   {:exit, "b", index}
                 ]
               end)

      assert calls != []
    end

    test "concurrency: :parallel is accepted" do
      assert {:ok, _stats} = run!([step("a"), step("b")], concurrency: :parallel)
    end

    test "concurrency: :serial is accepted and any other value is rejected" do
      assert {:ok, _stats} = run!([step("a"), step("b")], concurrency: :serial)

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

    test "latency: with concurrency: :parallel is an option error" do
      # The same measurement runs under :serial.
      assert {:ok, _stats} = run!([step("a"), step("b")], latency: true, concurrency: :serial)

      for latency <- [true, [p95: [max_ratio: 1.5]]] do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            run!([step("a"), step("b")], latency: latency, concurrency: :parallel)
          end

        assert error.message =~ "concurrency: :serial"
      end
    end

    test "the report names the failing target and its kind, and no longer an execution mode" do
      keys = FailureReport |> struct() |> Map.keys()

      assert :kind in keys
      assert :variant in keys
      assert :targets in keys
      refute :execution in keys
      refute :adapter in keys
    end

    test "per-target injectors and mocks are accepted and set up per run" do
      mock = {CountingMock, %{name: "mock", test_pid: self()}}

      assert {:ok, _stats} =
               run!(
                 [step("a"), step("b", %{}, injectors: [NoteInjector], mocks: [mock])],
                 max_runs: 3
               )

      assert length(take_messages(:mock_setup)) == 3
    end
  end

  describe "boundary observations and divergences" do
    test "a divergence names the root, the variant, the observation and both values" do
      # Unshrunk, so the values are those of the generated command. Both
      # targets inject a Noted event, which the observation does not fold.
      report =
        failure!([step("a", %{behavior: :inject}), step("b", %{behavior: :inject_shift})],
          shrink: false
        )

      assert report.kind == :diverged
      divergence = Failure.detail(report.failure_reason)

      assert divergence |> Map.keys() |> Enum.sort() ==
               [:command, :key, :mismatch, :reference_value, :root, :variant_value]

      assert divergence.key == {PropertyDamage.Test.Lockstep.Answers, :answers}

      assert %Step{value: value} =
               Enum.at(Sequence.to_list(report.original_sequence), divergence.root)

      assert divergence.command ==
               Enum.at(Sequence.to_list(report.original_sequence), divergence.root)

      assert report.seed == @seed
      assert report.run_number == 0
      assert divergence.root == 0
      assert report.failed_at_index == 0
      assert report.variant == %{index: 1, name: "b"}

      assert divergence.reference_value == %{stepped: [{value, nil}], probed: []}
      assert divergence.variant_value == %{stepped: [{value + 1, nil}], probed: []}
      assert divergence.mismatch.left == divergence.reference_value
      assert divergence.mismatch.right == divergence.variant_value
    end

    test "a divergence after root 0 names that root and its command" do
      report = failure!([step("a"), step("b", %{bad_at: 1})], max_commands: 3)

      divergence = Failure.detail(report.failure_reason)
      assert divergence.root == 1

      assert Enum.at(Sequence.to_list(report.original_sequence), 1) ==
               Enum.at(generated(StepModel, @seed, 0, 3), 1)

      assert [{_value, :bad} | _] = divergence.variant_value.stepped
    end

    test "an adapter {:error, reason} in one target is that target's failure, not a divergence" do
      report = failure!([step("a"), step("b", %{behavior: :error})], shrink: false)

      assert report.kind == :execution_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == 0
      assert Failure.kind(report.failure_reason) == :adapter_error
      assert Failure.detail(report.failure_reason) == :refused

      # The report's state is the failing target's: nothing it answered was folded.
      assert report.state_at_failure[PropertyDamage.Test.Lockstep.Answers].stepped == []
    end

    test "an observation that folds no identifiers ignores them; one that folds them diverges" do
      targets = [step("a"), step("b", %{behavior: :new_id})]

      assert {:ok, _stats} = run!(targets)

      assert {:error, %FailureReport{kind: :diverged}} =
               run!(targets, model: __MODULE__.IdModel)
    end

    test "a using: predicate decides whether the two values agree" do
      targets = [step("a"), step("b", %{behavior: :shift})]

      assert {:ok, _stats} = run!(targets, model: __MODULE__.CloseModel)

      assert {:error, %FailureReport{kind: :diverged}} =
               run!(targets, model: __MODULE__.NeverModel)
    end

    test "a run stops at its first divergence and the campaign ends with it" do
      recorder = start_recorder()

      report =
        failure!([step("a"), step("b", %{behavior: :shift, recorder: recorder})],
          max_runs: 4,
          shrink: false
        )

      assert report.kind == :diverged
      assert report.run_number == 0
      assert report.failed_at_index == 0
      # Run 0 stepped root 0 and stopped; the second 0 is the failure's
      # reproduction, a re-execution of run 0. No later run started.
      assert entered(recorder, "b") == [0, 0]
    end

    test "a probe root that retries before settling is compared on its settled value" do
      targets = [
        {ProbeAdapter, name: "a", config: %{retries: 2}},
        {ProbeAdapter, name: "b", config: %{retries: 2}}
      ]

      assert {:ok, _stats} = run!(targets, model: ProbeModel, max_runs: 2)

      shifted =
        failure!(
          [
            {ProbeAdapter, name: "a", config: %{retries: 2}},
            {ProbeAdapter, name: "b", config: %{retries: 1, offset: 1}}
          ],
          model: ProbeModel
        )

      # The comparison re-read the probe root while it waited, so each side
      # folded its settled value more than once; the latest read leads.
      divergence = Failure.detail(shifted.failure_reason)
      assert [value | _] = divergence.reference_value.probed
      assert [shifted_value | _] = divergence.variant_value.probed
      assert shifted_value == value + 1
    end
  end

  describe "failures" do
    test "an adapter raise in one variant is an execution failure naming it, never a divergence" do
      report = failure!([step("a"), step("b", %{behavior: :raise})])

      assert report.kind == :execution_failed
      assert report.variant == %{index: 1, name: "b"}
      assert report.run_number == 0
      assert report.failed_at_index == 0

      assert %Failure{
               type: %Failure.Execution{
                 kind: :adapter_error,
                 detail: %RuntimeError{message: "candidate exploded"}
               }
             } = report.failure_reason
    end

    test "a check failure in the non-reference variant is a failure, and later variants of that root do not run" do
      recorder = start_recorder()

      report =
        failure!(
          [
            step("a", %{recorder: recorder}),
            step("b", %{recorder: recorder, bad_at: 1}),
            step("c", %{recorder: recorder})
          ],
          model: GuardedStepModel,
          shrink: false
        )

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, run_number: 0} = report
      assert report.failed_at_index == 1

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} =
               report.failure_reason

      # The run, then the failure's reproduction, each stopping at root 1.
      assert entered(recorder, "a") == [0, 1, 0, 1]
      assert entered(recorder, "b") == [0, 1, 0, 1]
      assert entered(recorder, "c") == [0, 0]
    end

    test "under :parallel a check failure stops the run before the next root starts" do
      recorder = start_recorder()

      report =
        failure!(
          [
            step("a", %{recorder: recorder}),
            step("b", %{recorder: recorder, bad_at: 1}),
            step("c", %{recorder: recorder})
          ],
          model: GuardedStepModel,
          concurrency: :parallel
        )

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, failed_at_index: 1} = report

      for name <- ["a", "b", "c"] do
        assert Enum.all?(entered(recorder, name), &(&1 <= 1))
      end
    end

    test "a :startup check that fails in one variant names it, with no root" do
      report = failure!([step("a"), step("b", %{fail_startup: true})], model: StartupModel)

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, run_number: 0} = report
      assert report.failed_at_index == nil

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :ready}} =
               report.failure_reason
    end

    test "a failure ends the campaign: no run after the failing one starts" do
      {:ok, counter} = Agent.start_link(fn -> %{} end)

      report =
        failure!(
          [
            step("a", %{counter: counter}),
            step("b", %{counter: counter, raise_on_run: 2})
          ],
          max_runs: 5,
          shrink: false
        )

      assert %{kind: :execution_failed, run_number: 2, variant: %{index: 1}} = report

      # Runs 0 to 2, then the reproduction of run 2 (which does not raise, so
      # the report keeps the original run). No run after the failing one was
      # started.
      assert Agent.get(counter, & &1) == %{"a" => 4, "b" => 4}
      assert report.trace.plan_source == :generated
    end
  end

  describe "pollers inside a multi-target run" do
    test "an adapter may start a resource poller and its events reach that variant" do
      # PolledModel's @eventually check passes only when every step's value was
      # delivered back by that variant's resource poller.
      assert {:ok, _stats} =
               run!(
                 [step("a", %{poll: :deliver}), step("b", %{poll: :deliver})],
                 model: PolledModel,
                 max_runs: 2
               )
    end

    test "a variant whose poller never delivers fails its @eventually check (control)" do
      report =
        failure!(
          [step("a", %{poll: :deliver}), step("b", %{poll: :never})],
          model: PolledModel
        )

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}} = report
    end
  end

  describe "latency measurement" do
    test "reports the latency metrics per target and excludes warm-up runs" do
      # "rejecting" answers every command with an event of its own, as a
      # system that rejects a request does; an event is never an error.
      assert {:ok, stats} =
               run!([step("fast"), step("rejecting", %{behavior: :shift})],
                 model: __MODULE__.LatencyModel,
                 latency: [warmup: 1],
                 max_runs: 3
               )

      assert stats.metrics |> Map.keys() |> Enum.sort() == ["fast", "rejecting"]

      measured =
        Enum.sum(for run <- 1..2, do: length(generated(StepModel, @seed, run, 3)))

      for name <- ["fast", "rejecting"] do
        metrics = stats.metrics[name]
        assert metrics |> Map.keys() |> Enum.sort() == @metric_keys
        assert metrics.commands == measured
      end
    end

    test "an adapter {:error, _} ends a latency run as that target's execution failure" do
      assert {:error, report} =
               run!([step("fast"), step("broken", %{behavior: :error})],
                 model: __MODULE__.LatencyModel,
                 latency: [warmup: 1],
                 max_runs: 3,
                 shrink: false
               )

      assert report.kind == :execution_failed
      assert report.variant == %{index: 1, name: "broken"}
      assert report.run_number == 0
    end
  end

  describe "per-run setup" do
    test "every target is set up and torn down once per run, in its own process, setups in target order" do
      recorder = start_recorder()
      config = %{test_pid: self(), recorder: recorder, setup_delay_ms: 20}

      assert {:ok, _stats} =
               run!([step("a", config), step("b", config)], max_runs: 3, max_commands: 2)

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
      assert {:ok, _stats} = Task.await(task, 5_000)
    end

    test "a setup error in variant 1 is a setup failure; variant 0 is torn down" do
      report =
        failure!([step("a", %{test_pid: self()}), step("b", %{setup_result: :error})],
          max_runs: 3
        )

      assert %{kind: :setup_failed, variant: %{index: 1, name: "b"}, run_number: 0} = report
      assert report.failed_at_index == nil
      assert Failure.detail(report.failure_reason) == :no_backend

      assert [{:setup, "a", setup_a}] = take_messages(:setup)
      assert [{:teardown, "a", ^setup_a}] = take_messages(:teardown)
    end

    test "a raising setup in variant 1 is a setup failure; variant 0 is torn down" do
      report = failure!([step("a", %{test_pid: self()}), step("b", %{setup_result: :raise})])

      assert %{kind: :setup_failed, variant: %{index: 1, name: "b"}} = report
      assert report.failed_at_index == nil
      assert %RuntimeError{message: "setup exploded"} = Failure.detail(report.failure_reason)

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
    test "divergent and failed reports format without error" do
      divergent = failure!([step("a"), step("b", %{behavior: :shift})])
      assert is_binary(FailureReport.Formatter.format(divergent, :terminal, color: false))

      failed = failure!([step("a"), step("b", %{behavior: :raise})])
      assert is_binary(FailureReport.Formatter.format(failed, :terminal, color: false))
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
