defmodule PropertyDamage.EngineTelemetryTest do
  # The engine emits command and check telemetry naming the target that
  # executed the command or evaluated the check.
  #
  # Not async: telemetry handlers are global. Events from other tests' runs are
  # filtered out by this module's target names.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.Lockstep.{
    GuardedStepModel,
    Ledger,
    PolledModel,
    Step,
    StepAdapter,
    StepGuard,
    StepModel
  }

  defmodule Forward do
    def handle_event(event, measurements, metadata, %{pid: pid}) do
      send(pid, {:telemetry, event, measurements, metadata})
    end
  end

  # Draws the failing value 13 often enough for a campaign to find its first
  # failure after run 0.
  defmodule LateFailureModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands do
      [{Step, overrides: fn _state -> %{value: StreamData.member_of([1, 1, 1, 13])} end}]
    end

    @impl true
    def command_sequence_projection, do: Ledger

    @impl true
    def check_projections, do: [StepGuard]
  end

  setup do
    id = "engine-telemetry-#{inspect(self())}"

    :telemetry.attach_many(
      id,
      [
        [:property_damage, :command, :start],
        [:property_damage, :command, :stop],
        [:property_damage, :check, :start],
        [:property_damage, :check, :stop],
        [:property_damage, :sequence, :stop]
      ],
      &Forward.handle_event/4,
      %{pid: self()}
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  defp target(name, config \\ %{}),
    do: {StepAdapter, name: name, config: Map.merge(%{name: name}, config)}

  defp run(model, targets, extra \\ []) do
    PropertyDamage.run(
      Keyword.merge(
        [
          model: model,
          targets: targets,
          max_runs: 1,
          max_commands: 4,
          seed: 4243,
          validate: false
        ],
        extra
      )
    )
  end

  # Every event of `name` received so far whose variant is one of `names`.
  defp collect(event, names) do
    collect(event, names, [])
  end

  defp collect(event, names, acc) do
    receive do
      {:telemetry, ^event, measurements, %{variant: %{name: name}} = metadata} ->
        if name in names,
          do: collect(event, names, [{measurements, metadata} | acc]),
          else: collect(event, names, acc)

      {:telemetry, _other, _measurements, _metadata} ->
        collect(event, names, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "command stop names both targets of a two-target run" do
    assert {:ok, _stats} = run(StepModel, [target("tel_a"), target("tel_b")])

    stops = collect([:property_damage, :command, :stop], ["tel_a", "tel_b"])
    assert stops != []

    variants = stops |> Enum.map(fn {_m, meta} -> meta.variant end) |> Enum.uniq()
    assert %{index: 0, name: "tel_a"} in variants
    assert %{index: 1, name: "tel_b"} in variants

    for {measurements, meta} <- stops do
      assert is_integer(measurements.duration)
      assert meta.command == PropertyDamage.Test.Lockstep.Step
      assert is_integer(meta.index)
      assert meta.run_number == 0
      assert meta.success == true
    end

    # Each target executed each command once, between its start and its stop.
    per_target = Enum.group_by(stops, fn {_m, meta} -> meta.variant.index end)
    assert length(per_target[0]) == length(per_target[1])
  end

  test "command stop names index 0 for a one-target run" do
    assert {:ok, _stats} = run(StepModel, [target("tel_solo")])

    stops = collect([:property_damage, :command, :stop], ["tel_solo"])
    assert stops != []
    assert Enum.all?(stops, fn {_m, meta} -> meta.variant == %{index: 0, name: "tel_solo"} end)
  end

  test "command stop names index 0 on the one-target branching path" do
    assert {:ok, _stats} =
             run(StepModel, [target("tel_branch")],
               max_commands: 6,
               branching: [branch_probability: 1.0]
             )

    stops = collect([:property_damage, :command, :stop], ["tel_branch"])
    assert stops != []
    assert Enum.all?(stops, fn {_m, meta} -> meta.variant == %{index: 0, name: "tel_branch"} end)
  end

  # A command's `index` counts across the whole run: a branching sequence
  # numbers its prefix, then each branch from the end of the prefix, then the
  # suffix after every branch command.
  describe "command index" do
    alias PropertyDamage.{Executor, Sequence}
    alias PropertyDamage.Test.Lockstep.Step

    defp indices(sequence, name) do
      context = PropertyDamage.Telemetry.engine_context(%{index: 0, name: name}, 0)

      assert {:ok, %{success: true}} =
               Executor.run(sequence, StepModel, StepAdapter,
                 config: %{name: name},
                 telemetry: context
               )

      [:property_damage, :command, :stop]
      |> collect([name])
      |> Enum.map(fn {_measurements, meta} -> {meta.phase, meta.index, meta.root_index} end)
      |> Enum.sort()
    end

    defp steps(count), do: for(value <- 1..count//1, do: %Step{value: value})

    test "is cumulative across prefix, branches and suffix" do
      sequence = Sequence.branching(steps(2), [steps(2), steps(1)], steps(2))

      # Both branches start at the index after the prefix; the suffix starts
      # after all three branch commands.
      assert indices(sequence, "idx_branch") == [
               {:root, 0, 0},
               {:root, 1, 1},
               {:root, 2, 2},
               {:root, 2, 2},
               {:root, 3, 3},
               {:root, 5, 5},
               {:root, 6, 6}
             ]
    end

    test "is the position in the sequence on the linear path" do
      assert indices(Sequence.linear(steps(3)), "idx_linear") ==
               [{:root, 0, 0}, {:root, 1, 1}, {:root, 2, 2}]
    end
  end

  test "the reproduction of a failure emits the run number that found it" do
    assert {:error, report} =
             run(LateFailureModel, [target("tel_repro")],
               max_runs: 20,
               max_commands: 2,
               seed: 10,
               replay_dir: false
             )

    # The failure is first found after run 0; the reproduction is the last
    # execution of the campaign.
    assert report.run_number > 0

    run_numbers =
      [:property_damage, :command, :stop]
      |> collect(["tel_repro"])
      |> Enum.map(fn {_measurements, meta} -> meta.run_number end)

    assert List.last(run_numbers) == report.run_number
  end

  test "check stop names the target and the check" do
    assert {:ok, _stats} = run(GuardedStepModel, [target("tel_ca"), target("tel_cb")])

    stops = collect([:property_damage, :check, :stop], ["tel_ca", "tel_cb"])
    assert stops != []

    for {measurements, meta} <- stops do
      assert is_integer(measurements.duration)
      assert meta.check_name == :step_is_good
      assert meta.passed == true
    end

    variants = stops |> Enum.map(fn {_m, meta} -> meta.variant.index end) |> Enum.uniq()
    assert Enum.sort(variants) == [0, 1]
  end

  test "check stop reports a failing check with its message" do
    assert {:error, report} =
             run(GuardedStepModel, [target("tel_fail", %{bad_at: 0})], shrink: false)

    assert report.kind == :check_failed

    stops = collect([:property_damage, :check, :stop], ["tel_fail"])
    assert Enum.any?(stops, fn {_m, meta} -> meta.passed == false and is_binary(meta.message) end)
  end

  # Every check event received so far for an `@eventually` check named
  # `:stepped_is_polled` whose variant is `name`, as `{event, measurements, metadata}`.
  defp polled_check_events(name, acc \\ []) do
    receive do
      {:telemetry, [:property_damage, :check, _] = event, measurements,
       %{check_name: :stepped_is_polled, variant: %{name: ^name}} = metadata} ->
        polled_check_events(name, [{event, measurements, metadata} | acc])

      {:telemetry, _event, _measurements, _metadata} ->
        polled_check_events(name, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "an @eventually check emits check start and stop with the synchronous check's keys" do
    assert {:ok, _stats} = run(PolledModel, [target("tel_ev", %{poll: :deliver})])

    events = polled_check_events("tel_ev")
    starts = for {[_, _, :start], _m, meta} <- events, do: meta
    stops = for {[_, _, :stop], m, meta} <- events, do: {m, meta}

    assert [start_meta | _] = starts
    assert Enum.sort(Map.keys(start_meta)) == [:check_name, :projection, :run_number, :variant]
    assert start_meta.projection == PropertyDamage.Test.Lockstep.PolledProjection
    assert length(stops) == length(starts)

    for {measurements, meta} <- stops do
      assert is_integer(measurements.duration)

      assert Enum.sort(Map.keys(meta)) ==
               [:check_name, :message, :passed, :projection, :run_number, :variant]

      assert meta.passed == true
    end

    assert {:error, _report} =
             run(PolledModel, [target("tel_ev_never", %{poll: :never})], shrink: false)

    assert Enum.any?(polled_check_events("tel_ev_never"), fn
             {[_, _, :stop], _m, meta} -> meta.passed == false and is_binary(meta.message)
             _start -> false
           end)
  end

  test "sequence stop names the failing target, nil for a passing run" do
    assert {:ok, _stats} = run(StepModel, [target("tel_sa"), target("tel_sb")])
    assert_received {:telemetry, [:property_damage, :sequence, :stop], _, %{variant: nil}}

    assert {:error, _report} =
             run(StepModel, [target("tel_da"), target("tel_db", %{behavior: :shift})],
               shrink: false
             )

    assert_received {:telemetry, [:property_damage, :sequence, :stop], _,
                     %{success: false, variant: %{index: 1, name: "tel_db"}}}
  end
end
