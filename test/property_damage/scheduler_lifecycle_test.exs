defmodule PropertyDamage.SchedulerLifecycleTest do
  # How a lockstep run treats the processes it starts: the barrier before
  # command 0, a crashed variant, a variant whose owner exits, per-step
  # latency, injectors whose module is not loaded yet, and how a failure
  # is printed.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{Failure, FailureReport, Generator, Scheduler, Sequence, Variant}
  alias PropertyDamage.Progress.Printer
  alias PropertyDamage.Test.LatencyFixtures.{RefusingMintAdapter, SlowFoldModel, TimedStepAdapter}
  alias PropertyDamage.Test.LazyInjector

  alias PropertyDamage.Test.Lockstep.{
    Create,
    Noted,
    RoutingModel,
    StartupModel,
    Step,
    StepAdapter,
    StepModel,
    Use
  }

  defmodule SelfKillingAdapter do
    @moduledoc false
    # Kills the variant process that runs it when it executes a step whose
    # value is `kill_at`, as an unexpected crash of that process would.
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Lockstep.{Step, Stepped}

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Step{value: value}, ctx, _runtime) do
      if value == ctx.kill_at do
        [variant | _] = Process.get(:"$callers")
        Process.exit(variant, :kill)
      end

      {:ok, [%Stepped{value: value}]}
    end
  end

  defp run_opts(model, targets, commands, extra \\ []) do
    Keyword.merge(
      [
        model: model,
        targets: targets,
        commands: commands,
        seed: 7,
        run_number: 0,
        run_nonce: 1,
        concurrency: :serial
      ],
      extra
    )
  end

  defp entered(recorder, name) do
    for {:enter, ^name, index} <- recorded(recorder), do: index
  end

  test "a failing :startup check in a later variant stops the run before any variant executes command 0" do
    recorder = start_recorder()

    targets =
      targets!([
        {StepAdapter, name: "a", config: %{name: "a", recorder: recorder}},
        {StepAdapter, name: "b", config: %{name: "b", recorder: recorder, fail_startup: true}}
      ])

    assert {:ok, run} =
             Scheduler.run(run_opts(StartupModel, targets, [%Step{value: 1}, %Step{value: 2}]))

    assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, root: nil} = run.failure
    assert entered(recorder, "a") == []
    assert entered(recorder, "b") == []
  end

  test "a variant process that crashes is an execution failure naming it, not an exit out of run/1" do
    targets =
      targets!([
        {SelfKillingAdapter, name: "a", config: %{kill_at: nil}},
        {SelfKillingAdapter, name: "b", config: %{kill_at: 2}}
      ])

    commands = for value <- 1..3, do: %Step{value: value}

    assert {:ok, run} = Scheduler.run(run_opts(StepModel, targets, commands))

    assert %{kind: :execution_failed, variant: %{index: 1, name: "b"}, run: 0, root: 1} =
             run.failure

    assert %Failure{} = run.failure.reason
    assert Failure.detail(run.failure.reason) == {:exit, :killed}
  end

  test "a variant started with start/1 tears its adapter down when the process that started it exits" do
    test_pid = self()

    [target] =
      targets!([{StepAdapter, name: "solo", config: %{name: "solo", test_pid: test_pid}}])

    owner =
      spawn(fn ->
        {:ok, pid} = Variant.start(variant_opts(target, StepModel, [%Step{value: 1}]))
        :ok = Variant.setup(pid)
        send(test_pid, {:variant, pid})
      end)

    assert_receive {:variant, pid}, 2_000
    ref = Process.monitor(pid)
    refute Process.alive?(owner)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    assert_receive {:teardown, "solo", ^pid}, 2_000
  end

  test "measure_latency: true records the wall-clock time of every adapter call" do
    [target] = targets!([{StepAdapter, name: "solo", config: %{name: "solo", hold_ms: 20}}])
    commands = [%Step{value: 1}, %Step{value: 2}]

    {:ok, pid} =
      Variant.start_link(variant_opts(target, StepModel, commands, measure_latency: true))

    :ok = Variant.setup(pid)
    {:ok, _observed} = Variant.advance_to(pid, 1)

    assert [{0, first}, {1, second}] = Variant.latencies(pid)
    assert first >= 20_000
    assert second >= 20_000

    Variant.finish(pid)
    Variant.stop(pid)
  end

  test "an injector whose module was not loaded yet is still set up" do
    # Unload the module so the run is the first to touch it.
    :code.purge(LazyInjector)
    :code.delete(LazyInjector)
    :code.purge(LazyInjector)
    refute :code.is_loaded(LazyInjector)

    targets =
      targets!([{StepAdapter, name: "solo", config: %{name: "solo"}, injectors: [LazyInjector]}])

    assert {:ok, run} = Scheduler.run(run_opts(StepModel, targets, [%Step{value: 1}]))
    assert [result] = run.results
    assert events_from(result.event_log, :injector) == [%Noted{value: :lazy}]
  end

  test "a failed report prints the failure's kind, variant, run, root and reason" do
    commands = for value <- 1..4, do: %Step{value: value}

    report =
      FailureReport.new(
        seed: 1,
        run_number: 0,
        original_sequence: Sequence.linear(commands),
        failed_at_index: 3,
        failure_reason: Failure.adapter_error(%RuntimeError{message: "candidate exploded"}),
        targets: [{StepAdapter, name: "a"}, {StepAdapter, name: "b"}],
        variant: %{index: 1, name: "b"}
      )

    output =
      ExUnit.CaptureIO.capture_io(fn -> Printer.print_failure(report) end)

    assert output =~ "Kind:         execution_failed"
    assert output =~ "Target:       [1] b"
    assert output =~ "Run:          1"
    assert output =~ "Failed at:    Command 4"
    assert output =~ "candidate exploded"
  end

  describe "an unresolved placeholder under lockstep" do
    # A seed whose run 0 has a Create, a later Use consuming its id, and a
    # Create after that Use.
    defp routing_seed do
      Enum.find_value(1..500, fn seed ->
        commands = routing_commands(seed)
        first_create = Enum.find_index(commands, &match?(%Create{}, &1))
        use_at = Enum.find_index(commands, &match?(%Use{}, &1))

        if first_create && use_at && use_at > first_create &&
             Enum.any?(Enum.drop(commands, use_at + 1), &match?(%Create{}, &1)) do
          {seed, commands, first_create}
        end
      end)
    end

    defp routing_commands(seed) do
      RoutingModel
      |> Generator.generate_sequence(max_commands: 12)
      |> Generator.generate_value(Generator.run_seed(seed, 0))
      |> Sequence.to_list()
    end

    defp mint_target(name, refuse) do
      {RefusingMintAdapter,
       name: name, config: %{prefix: name, refuse_create: refuse, test_pid: self()}}
    end

    defp run_routing(seed, targets) do
      PropertyDamage.run(
        model: RoutingModel,
        targets: targets,
        compare: [converge_within: 30],
        max_runs: 1,
        max_commands: 12,
        seed: seed,
        validate: false,
        shrink: false
      )
    end

    defp received(prefix) do
      for {:received, ^prefix, command} <- take_messages(:received), do: command
    end

    test "when every variant's producer errored, the reference fails there and no Use runs" do
      {seed, commands, first_create} = routing_seed()

      assert {:error, report} =
               run_routing(seed, [mint_target("a", true), mint_target("b", true)])

      assert report.kind == :execution_failed
      assert report.variant == %{index: 0, name: "a"}
      assert report.failed_at_index == first_create
      assert Failure.detail(report.failure_reason) == :refused
      assert report.other_failures == []

      messages = take_messages(:received)
      sent = fn prefix -> for {:received, ^prefix, command} <- messages, do: command end

      # The run (and its reproduction) stopped at the first Create: the
      # reference refused it, and under :serial "b" never started that root.
      assert Enum.all?(sent.("a"), &match?(%Create{}, &1))
      assert sent.("a") != []
      assert sent.("b") == []
      assert Enum.at(commands, first_create).__struct__ == Create
    end

    test "when only a non-reference producer errored, that variant fails at the producer" do
      {seed, _commands, first_create} = routing_seed()

      assert {:error, %FailureReport{kind: :execution_failed} = report} =
               run_routing(seed, [mint_target("a", false), mint_target("b", true)])

      assert report.variant == %{index: 1, name: "b"}
      assert report.failed_at_index == first_create
      assert Failure.detail(report.failure_reason) == :refused

      # With no other variant left to compare, the run ended there: no Use
      # reached either adapter.
      assert received("b") != []
      refute Enum.any?(received("a"), &match?(%Use{}, &1))
    end
  end

  describe "latency measurement" do
    defp timed_run(targets) do
      {:ok, stats} =
        PropertyDamage.run(
          model: SlowFoldModel,
          targets: targets,
          latency: true,
          max_runs: 2,
          max_commands: 3,
          seed: 31,
          validate: false
        )

      stats
    end

    test "times the adapter's execute/3, not the projection folds after it" do
      result =
        timed_run([{TimedStepAdapter, name: "a"}, {TimedStepAdapter, name: "b"}])

      for name <- ["a", "b"] do
        metrics = result.metrics[name]
        assert metrics.total_commands > 0
        # Each step folds through a projection that sleeps 40 ms per event.
        assert metrics.latency_max < 20_000
      end
    end

    test "control: an adapter that sleeps shows in latency_min" do
      result =
        timed_run([
          {TimedStepAdapter, name: "a"},
          {TimedStepAdapter, name: "b", config: %{sleep_ms: 30}}
        ])

      assert result.metrics["b"].latency_min >= 30_000
      assert result.metrics["a"].latency_max < 20_000
    end
  end
end
