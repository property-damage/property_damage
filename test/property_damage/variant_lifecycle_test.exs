defmodule PropertyDamage.VariantLifecycleTest do
  # A variant reaps a resource poller even when it is killed in the middle of
  # a command, and a lockstep run reports a check failure at the command the
  # engine attributes it to, under :halt and under :record.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{EventQueue, Failure, Generator, Scheduler, Variant}

  alias PropertyDamage.Test.Lockstep.{
    CountingMock,
    Deliver,
    Delivered,
    GuardedStepModel,
    Late,
    Ledger,
    Probed,
    Step,
    StepAdapter
  }

  defmodule SlowProbe do
    @moduledoc false
    # Waits 800 ms between settle attempts, so a test can act while the
    # variant sleeps between them.
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 10_000, interval_ms: 800, backoff: :linear}

    defstruct [:value]

    @impl true
    def generator(_overrides \\ %{}), do: StreamData.constant(%{value: 1})
  end

  defmodule SlowProbeModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [SlowProbe]

    @impl true
    def command_sequence_projection, do: Ledger
  end

  defmodule PollingProbeAdapter do
    @moduledoc false
    # The first attempt starts a resource poller that never delivers, reports
    # it to `test_pid` as {:poller_started, poller, attempt_pid}, and asks to
    # be retried; the second attempt settles.
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, Map.put(config, :attempts, :atomics.new(1, []))}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%SlowProbe{value: value}, ctx, runtime) do
      if :atomics.add_get(ctx.attempts, 1, 1) == 1 do
        poller =
          runtime.start_poller.(
            poll_fn: fn -> :tick end,
            handler: fn _ -> :continue end,
            interval_ms: 10,
            timeout_ms: 10_000,
            on_timeout: :ignore
          )

        send(ctx.test_pid, {:poller_started, poller.pid, self()})
        {:retry, :not_yet}
      else
        {:ok, [%Probed{value: value}]}
      end
    end
  end

  defmodule LateGuard do
    @moduledoc false
    # Fails on a Late event that came from a bad source.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: Late
    def assert_late_is_fine(_state, %Late{from: from}) do
      if from == :bad, do: PropertyDamage.fail!("bad late event", from: from)
      :ok
    end
  end

  defmodule LateModel do
    @moduledoc false
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: [Deliver]

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [LateGuard]
  end

  defmodule LateAdapter do
    @moduledoc false
    # `{:start, agent}` starts a poller that delivers %Late{from: late_from}
    # once it receives :go; `{:release, agent}` sends it :go and waits until it
    # exited, so the event sits in the queue when this command's step drains.
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%Deliver{coordinator: {:start, agent}}, ctx, runtime) do
      poller =
        runtime.start_poller.(
          poll_fn: fn ->
            receive do
              :go -> :ready
            after
              10_000 -> :never
            end
          end,
          handler: fn
            :ready -> {:done, [%Late{from: ctx.late_from}]}
            :never -> {:done, []}
          end,
          interval_ms: 10,
          timeout_ms: 20_000
        )

      Agent.update(agent, fn _ -> poller.pid end)
      {:ok, [%Delivered{}]}
    end

    def execute(%Deliver{coordinator: {:release, agent}}, _ctx, _runtime) do
      poller = Agent.get(agent, & &1)
      ref = Process.monitor(poller)
      send(poller, :go)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        2_000 -> :ok
      end

      {:ok, [%Delivered{}]}
    end

    def execute(%Deliver{coordinator: nil}, _ctx, _runtime), do: {:ok, [%Delivered{}]}
  end

  describe "killing a variant" do
    defp start_probe_variant do
      [target] =
        targets!([
          {PollingProbeAdapter,
           name: "a", config: %{test_pid: self()}, mocks: [{CountingMock, %{name: "m"}}]}
        ])

      commands = [%SlowProbe{value: 1}]
      {:ok, pid} = Variant.start(variant_opts(target, SlowProbeModel, commands))
      :ok = Variant.setup(pid)
      snapshot = Variant.snapshot(pid)
      {pid, snapshot.event_queue, snapshot.mock_registry}
    end

    defp advance_in_task(pid) do
      Task.async(fn ->
        try do
          Variant.advance_to(pid, 0)
        catch
          :exit, reason -> {:exit, reason}
        end
      end)
    end

    defp assert_down(ref) do
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
    end

    test "while it waits between settle attempts leaves no resource poller, queue or mock registry" do
      {pid, queue, registry} = start_probe_variant()
      task = advance_in_task(pid)

      assert_receive {:poller_started, poller, attempt}, 3_000
      # The attempt that started the poller has finished; the variant now
      # sleeps until the next attempt.
      attempt_ref = Process.monitor(attempt)
      assert_receive {:DOWN, ^attempt_ref, :process, ^attempt, _reason}, 2_000
      assert Process.alive?(poller)

      refs = for p <- [queue, registry, poller], do: Process.monitor(p)
      variant_ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^variant_ref, :process, ^pid, :killed}, 1_000
      assert {:exit, _reason} = Task.await(task, 5_000)

      Enum.each(refs, &assert_down/1)
    end

    test "control: after the step returned leaves no resource poller either" do
      {pid, queue, registry} = start_probe_variant()
      task = advance_in_task(pid)

      assert_receive {:poller_started, poller, _attempt}, 3_000
      assert {:ok, [{0, {:ok, [%Probed{value: 1}]}}]} = Task.await(task, 15_000)
      assert Process.alive?(poller)

      refs = for p <- [queue, registry, poller], do: Process.monitor(p)
      Process.exit(pid, :kill)

      Enum.each(refs, &assert_down/1)
    end
  end

  describe "the root of a check that fails on a drained event" do
    defp late_commands do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      [
        %Deliver{coordinator: {:start, agent}},
        %Deliver{coordinator: {:release, agent}},
        %Deliver{coordinator: nil}
      ]
    end

    defp late_run(late_from) do
      targets = targets!([{LateAdapter, name: "a", config: %{late_from: late_from}}])

      {:ok, run} =
        Scheduler.run(
          model: LateModel,
          targets: targets,
          commands: late_commands(),
          seed: 1,
          run_number: 0,
          run_nonce: 1,
          concurrency: :serial
        )

      run
    end

    defp linear_failed_at_index do
      {:ok, queue} = EventQueue.start_link()

      result =
        executor_run(late_commands(), LateModel, LateAdapter,
          config: %{late_from: :bad},
          event_queue: queue,
          rng_seed: Generator.run_seed(1, 0),
          run_nonce: 1,
          mint_epoch: 0
        )

      EventQueue.stop(queue)
      result.failed_at_index
    end

    test "is the command the event belongs to, as the result and the linear engine report it" do
      run = late_run(:bad)
      [result] = run.results

      assert %{kind: :check_failed, root: 0} = run.failure
      assert result.failed_at_index == 0
      assert linear_failed_at_index() == 0
    end

    test "control: a good late event fails nothing and belongs to command 0" do
      run = late_run(:good)
      [result] = run.results

      assert run.failure == nil
      assert {:resource_poller, 0, %Late{from: :good}} in entries(result.event_log)
    end
  end

  describe "check_mode: :record" do
    defp guarded_run(check_mode) do
      targets =
        targets!([
          {StepAdapter, name: "a", config: %{name: "a"}},
          {StepAdapter, name: "b", config: %{name: "b", bad_at: 1}}
        ])

      {:ok, run} =
        Scheduler.run(
          model: GuardedStepModel,
          targets: targets,
          commands: for(value <- 1..3, do: %Step{value: value}),
          seed: 1,
          run_number: 0,
          run_nonce: 1,
          concurrency: :serial,
          compare: [converge_within: 30],
          check_mode: check_mode
        )

      run
    end

    test "names the first recorded check failure's command and Failure" do
      run = guarded_run(:record)

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, root: 1} = run.failure

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} =
               run.failure.reason
    end

    test "control: under :halt the same input names the same command" do
      run = guarded_run(:halt)

      assert %{kind: :check_failed, variant: %{index: 1, name: "b"}, root: 1} = run.failure

      assert %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}} =
               run.failure.reason
    end
  end
end
