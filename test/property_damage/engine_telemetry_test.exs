defmodule PropertyDamage.EngineTelemetryTest do
  # The engine emits command and check telemetry naming the target that
  # executed the command or evaluated the check.
  #
  # Not async: telemetry handlers are global. Events from other tests' runs are
  # filtered out by this module's target names.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.Lockstep.{GuardedStepModel, StepAdapter, StepModel}

  defmodule Forward do
    def handle_event(event, measurements, metadata, %{pid: pid}) do
      send(pid, {:telemetry, event, measurements, metadata})
    end
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
