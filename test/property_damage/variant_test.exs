defmodule PropertyDamage.VariantTest do
  # One variant runs one target over one concrete command sequence in its own
  # process, stepping through the full per-command engine path.
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport

  alias PropertyDamage.{EventQueue, Generator, Placeholder, Sequence}
  alias PropertyDamage.Stutter.Config, as: StutterConfig

  alias PropertyDamage.Test.Lockstep.{
    Begin,
    ClosedWebhook,
    CloseIssue,
    Confirmed,
    Deliver,
    Delivered,
    DrainAdapter,
    DrainModel,
    IssueAdapter,
    IssueModel,
    Late,
    Ledger,
    MintingAdapter,
    Nudge,
    OwnershipAdapter,
    OwnershipModel,
    OwnershipProjection,
    ProbeAdapter,
    Probed,
    ProbeModel,
    ProbeStep,
    RoutingModel,
    RoutingProjection,
    Step,
    StepAdapter,
    StepModel,
    Stepped,
    TimedFault,
    Use,
    WebhookInjector
  }

  defp step_targets(names, extra_config \\ %{}) do
    targets!(
      for name <- names do
        {StepAdapter,
         name: name, config: Map.merge(%{name: name, test_pid: self()}, extra_config)}
      end
    )
  end

  describe "process ownership" do
    test "each variant runs setup and its commands in its own process" do
      [a, b] = step_targets(["a", "b"])
      commands = [%Step{value: 1}]

      va = start_ready_variant(a, StepModel, commands)
      vb = start_ready_variant(b, StepModel, commands)

      assert_received {:setup, "a", setup_a}
      assert_received {:setup, "b", setup_b}
      assert setup_a == va
      assert setup_b == vb
      assert va != vb
      refute va == self()

      assert {:ok, [{0, _observation}]} = advance_to(va, 0)
      assert_received {:executed, "a", 0, callers}
      assert va in callers
      refute vb in callers

      :ok = stop_variant(va)
      :ok = stop_variant(vb)
      assert_received {:teardown, "a", ^va}
      assert_received {:teardown, "b", ^vb}
    end
  end

  describe "advance_to/2" do
    test "executes exactly the commands up to the boundary and resumes from the same state" do
      recorder = start_recorder()
      [target] = targets!([{StepAdapter, name: "a", config: %{name: "a", recorder: recorder}}])
      commands = for value <- 1..4, do: %Step{value: value}
      v = start_ready_variant(target, StepModel, commands)

      assert {:ok, roots} = advance_to(v, 1)
      assert Enum.map(roots, &elem(&1, 0)) == [0, 1]
      assert entered(recorder) == [0, 1]

      before = snapshot(v)
      assert before.step_count == 2

      assert {:ok, [{2, {:ok, [%Stepped{value: 3}]}}]} = advance_to(v, 2)
      assert entered(recorder) == [0, 1, 2]

      resumed = snapshot(v)
      assert resumed.step_count == 3
      assert length(resumed.event_log) == length(before.event_log) + 1
      assert resumed.projections[Ledger].stepped == [3, 2, 1]

      :ok = stop_variant(v)
    end

    test "a probe root's observation is its settled events" do
      [target] = targets!([{ProbeAdapter, name: "probe", config: %{retries: 2}}])
      v = start_ready_variant(target, ProbeModel, [%ProbeStep{value: 5}])

      assert {:ok, [{0, {:ok, [%Probed{value: 5}]}}]} = advance_to(v, 0)

      :ok = stop_variant(v)
    end
  end

  describe "isolation between variants" do
    test "two variants of one sequence share no written state" do
      commands = routed_commands()
      last = length(commands) - 1

      [a, b] =
        targets!([
          {MintingAdapter, name: "a", config: %{prefix: "a", test_pid: self()}},
          {MintingAdapter, name: "b", config: %{prefix: "b", test_pid: self()}}
        ])

      va = start_ready_variant(a, RoutingModel, commands)
      vb = start_ready_variant(b, RoutingModel, commands)

      assert {:ok, roots_a} = advance_to(va, last)
      assert {:ok, roots_b} = advance_to(vb, last)
      snap_a = snapshot(va)
      snap_b = snapshot(vb)
      :ok = stop_variant(va)
      :ok = stop_variant(vb)

      received = take_messages(:received)
      used_a = for {:received, "a", %Use{target: t}} <- received, do: t
      used_b = for {:received, "b", %Use{target: t}} <- received, do: t

      # Each consumer was resolved with the value its own variant minted.
      assert used_a != []
      assert Enum.all?(used_a, &(is_binary(&1) and String.starts_with?(&1, "a_id_")))
      assert Enum.all?(used_b, &(is_binary(&1) and String.starts_with?(&1, "b_id_")))

      created_a = snap_a.projections[RoutingProjection].created
      created_b = snap_b.projections[RoutingProjection].created
      assert created_a != []
      assert Enum.all?(created_a, &String.starts_with?(&1, "a_id_"))
      assert Enum.all?(created_b, &String.starts_with?(&1, "b_id_"))

      assert roots_a != roots_b
      assert snap_a.projections != snap_b.projections

      # Nothing one variant wrote appears in the other's state.
      refute written(snap_b) =~ "a_id_"
      refute written(snap_a) =~ "b_id_"
    end
  end

  describe "pollers" do
    test "an @eventually poller and a resource poller fold into the variant that started them" do
      {:ok, gate} = Agent.start_link(fn -> false end)
      commands = [%Begin{id: "p1"}, %Nudge{}]

      [owner, other] =
        targets!([
          {OwnershipAdapter, name: "owner", config: %{poll: true, gate: gate}},
          {OwnershipAdapter, name: "other", config: %{poll: false, gate: gate}}
        ])

      v1 = start_ready_variant(owner, OwnershipModel, commands)
      v2 = start_ready_variant(other, OwnershipModel, commands)

      {:ok, _} = advance_to(v1, 0)
      {:ok, _} = advance_to(v2, 0)
      s1 = snapshot(v1)
      s2 = snapshot(v2)

      assert length(s1.active_pollers) == 1
      assert [resource_poller] = s1.active_resource_pollers
      assert s2.active_pollers == []
      assert s2.active_resource_pollers == []

      # Open the gate and wait until the resource poller pushed its event and
      # exited.
      ref = Process.monitor(resource_poller.pid)
      Agent.update(gate, fn _ -> true end)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      {:ok, _} = advance_to(v1, 1)
      {:ok, _} = advance_to(v2, 1)
      r1 = finish(v1)
      r2 = finish(v2)
      :ok = stop_variant(v1)
      :ok = stop_variant(v2)

      assert r1.success
      assert r1.projections[OwnershipProjection].confirmed == %{"p1" => true}

      assert [{:resource_poller, 0, %Confirmed{id: "p1"}}] =
               Enum.filter(entries(r1.event_log), &match?({_, _, %Confirmed{}}, &1))

      assert r2.success
      assert r2.projections[OwnershipProjection].confirmed == %{}
      refute Enum.any?(r2.event_log, &match?(%Confirmed{}, &1.event))
    end

    test "killing the variant process leaves no poller or event queue alive" do
      Process.flag(:trap_exit, true)
      {:ok, gate} = Agent.start_link(fn -> false end)

      [target] =
        targets!([{OwnershipAdapter, name: "owner", config: %{poll: true, gate: gate}}])

      v = start_ready_variant(target, OwnershipModel, [%Begin{id: "p1"}, %Nudge{}])
      {:ok, _} = advance_to(v, 0)
      snap = snapshot(v)

      pids =
        Enum.map(snap.active_pollers, & &1.pid) ++
          Enum.map(snap.active_resource_pollers, & &1.pid) ++ [snap.event_queue]

      assert length(pids) == 3
      assert Enum.all?(pids, &Process.alive?/1)
      refs = Enum.map(pids, &Process.monitor/1)

      Process.exit(v, :kill)
      assert_receive {:EXIT, ^v, :killed}, 1_000

      for ref <- refs do
        assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
      end

      refute Enum.any?(pids, &Process.alive?/1)
    end

    test "an event delivered after the last step is in the boundary state" do
      {:ok, first} = Agent.start_link(fn -> nil end)
      {:ok, second} = Agent.start_link(fn -> nil end)
      commands = [%Deliver{coordinator: first}, %Deliver{coordinator: second}]
      [target] = targets!([{DrainAdapter, name: "drain"}])
      v = start_ready_variant(target, DrainModel, commands)

      # Command 0's resource poller pushes Late after the step's own queue drain,
      # so Late is still queued when the step returns.
      assert {:ok, [{0, observation}]} = advance_to(v, 0)
      snap = snapshot(v)

      assert [{:resource_poller, 0, %Late{from: :poller}}] =
               Enum.filter(entries(snap.event_log), &match?({_, _, %Late{}}, &1))

      assert snap.projections[Ledger].late == [:poller]
      assert EventQueue.size(snap.event_queue) == 0

      # The late event belongs to the poller, not to root 0's observation.
      assert observation == {:ok, [%Delivered{}]}

      {:ok, _} = advance_to(v, 1)
      _ = finish(v)
      :ok = stop_variant(v)
    end
  end

  describe "engine duties inside a variant" do
    test "an elapsed fault is restored after the step it outlived, in the variant process" do
      [target] = step_targets(["solo"])

      commands = [
        %TimedFault{duration_ms: 0, tag: :brief},
        %Step{value: 1},
        %TimedFault{duration_ms: 600_000, tag: :long},
        %Step{value: 2}
      ]

      v = start_ready_variant(target, StepModel, commands)

      {:ok, _} = advance_to(v, 0)
      assert_received {:fault_injected, :brief, ^v}
      assert_received {:fault_restored, :brief, ^v}

      {:ok, _} = advance_to(v, 3)
      assert_received {:fault_injected, :long, ^v}
      refute_received {:fault_restored, :long, _}

      # Finalizing restores the faults still active, in the variant process.
      result = finish(v)
      assert result.success
      assert_received {:fault_restored, :long, ^v}

      :ok = stop_variant(v)
    end

    test "a run with nemesis commands equals the linear engine's run" do
      commands = [
        %Step{value: 1},
        %TimedFault{duration_ms: 0, tag: :a},
        %Step{value: 2},
        %TimedFault{duration_ms: 600_000, tag: :b},
        %Step{value: 3}
      ]

      assert_same_as_executor(commands, StepModel, StepAdapter, %{name: "solo"})
    end

    test "a run with stutter enabled equals the linear engine's run" do
      stutter = %StutterConfig{
        probability: 0.5,
        max_repeats: 2,
        delay_ms: 0,
        commands: :all,
        enabled: true
      }

      commands = for value <- 1..8, do: %Step{value: value}

      {oracle, _variant} =
        assert_same_as_executor(commands, StepModel, StepAdapter, %{name: "solo"},
          stutter_config: stutter
        )

      # The run actually stuttered some commands and not others, so equality
      # depends on the variant deriving stutter decisions from the same seed.
      stuttered = for %{source: :stutter, command_index: i} <- oracle.event_log, uniq: true, do: i
      assert stuttered != []
      assert length(stuttered) < length(commands)
    end

    test "a run whose command awaits an injector event equals the linear engine's run" do
      commands = [%CloseIssue{issue_id: "i1"}]
      config = %{}
      seed = 99
      run_number = 2
      run_nonce = 42

      {:ok, queue} = EventQueue.start_link()
      {:ok, _} = WebhookInjector.setup(%{event_queue: queue})

      oracle =
        executor_run(commands, IssueModel, IssueAdapter,
          config: config,
          event_queue: queue,
          rng_seed: Generator.run_seed(seed, run_number),
          run_nonce: run_nonce,
          mint_epoch: 0
        )

      EventQueue.stop(queue)

      assert oracle.success
      assert {:injector, 0, %ClosedWebhook{issue_id: "i1"}} in entries(oracle.event_log)

      [target] =
        targets!([{IssueAdapter, name: "solo", config: config, injectors: [WebhookInjector]}])

      v =
        start_ready_variant(target, IssueModel, commands,
          seed: seed,
          run_number: run_number,
          run_nonce: run_nonce
        )

      {:ok, _} = advance_to(v, 0)
      result = finish(v)
      :ok = stop_variant(v)

      assert result.success
      assert result.projections == oracle.projections
      assert entries(result.event_log) == entries(oracle.event_log)
    end
  end

  describe "per-variant randomness" do
    test "each variant seeds its process RNG from the run seed and its index before setup" do
      seed = 2024
      run_number = 3
      targets = step_targets(["a", "b"], %{draw: true})

      variants =
        for target <- targets do
          start_ready_variant(target, StepModel, [%Step{value: 1}],
            seed: seed,
            run_number: run_number
          )
        end

      assert_received {:drawn, "a", drawn_a}
      assert_received {:drawn, "b", drawn_b}

      assert drawn_a == expected_draw(seed, run_number, 0)
      assert drawn_b == expected_draw(seed, run_number, 1)
      assert drawn_a != drawn_b

      Enum.each(variants, &stop_variant/1)
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp entered(recorder) do
    for {:enter, _name, index} <- recorded(recorder), do: index
  end

  defp written(snapshot) do
    inspect(
      {snapshot.projections, snapshot.event_log, snapshot.placeholder_registry},
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  # The first generated sequence that routes a minted value into a Use.
  defp routed_commands do
    generator = Generator.generate_sequence(RoutingModel, max_commands: 6)

    Enum.find_value(1..500, fn seed ->
      commands = generator |> Generator.generate_value(seed) |> Sequence.to_list()

      if Enum.any?(commands, &match?(%Use{target: %Placeholder{}}, &1)) do
        commands
      end
    end)
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

  # Runs `commands` once through the linear engine and once through a variant
  # with the same per-run options, and asserts both report the same
  # projections and event log.
  defp assert_same_as_executor(commands, model, adapter, config, extra \\ []) do
    seed = 7
    run_number = 1
    run_nonce = 42

    oracle =
      executor_run(
        commands,
        model,
        adapter,
        [
          config: config,
          rng_seed: Generator.run_seed(seed, run_number),
          run_nonce: run_nonce,
          mint_epoch: 0
        ] ++ extra
      )

    [target] = targets!([{adapter, name: "solo", config: config}])

    v =
      start_ready_variant(
        target,
        model,
        commands,
        [seed: seed, run_number: run_number, run_nonce: run_nonce] ++ extra
      )

    {:ok, _} = advance_to(v, length(commands) - 1)
    result = finish(v)
    :ok = stop_variant(v)

    assert result.success == oracle.success
    assert result.projections == oracle.projections
    assert entries(result.event_log) == entries(oracle.event_log)

    {oracle, result}
  end
end
