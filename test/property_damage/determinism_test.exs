defmodule PropertyDamage.DeterminismTest do
  @moduledoc """
  Verifies the "same seed → same run" promise for real: two runs with the
  same seed must execute the identical command sequence against the SUT,
  not merely echo the seed back.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.Commands.{CreateItem, MinimalCommand, ViewItem}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Test.FullModel

  defmodule RecordingAdapter do
    @moduledoc """
    Records every executed (resolved) command. Item refs are derived from a
    per-run counter so resolved values are themselves run-independent.
    """
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      {:ok, recorder} = Agent.start_link(fn -> %{commands: [], counter: 0} end)
      {:ok, Map.put(config, :recorder, recorder)}
    end

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(%CreateItem{} = cmd, ctx, _runtime) do
      ref =
        Agent.get_and_update(ctx.recorder, fn state ->
          {"item_#{state.counter}",
           %{state | commands: [cmd | state.commands], counter: state.counter + 1}}
        end)

      {:ok, [%ItemCreated{item_ref: ref, name: cmd.name, quantity: cmd.quantity}]}
    end

    def execute(%ViewItem{} = cmd, ctx, _runtime) do
      record(ctx, cmd)
      {:ok, [%ItemViewed{item_ref: cmd.item_ref}]}
    end

    def execute(%MinimalCommand{} = cmd, ctx, _runtime) do
      record(ctx, cmd)
      {:ok, []}
    end

    def recorded(ctx) do
      ctx.recorder |> Agent.get(& &1.commands) |> Enum.reverse()
    end

    defp record(ctx, cmd) do
      Agent.update(ctx.recorder, fn state ->
        %{state | commands: [cmd | state.commands]}
      end)
    end
  end

  defp run_and_record(seed) do
    {:ok, recorder} = Agent.start_link(fn -> %{commands: [], counter: 0} end)

    # Smuggle the shared recorder in via adapter_config so we can read it
    # back after the run (setup/1 receives the config).
    result =
      PropertyDamage.run(
        model: FullModel,
        adapter: __MODULE__.SharedRecorderAdapter,
        adapter_config: %{recorder: recorder},
        seed: seed,
        max_commands: 15,
        max_runs: 3,
        verbose: false,
        validate: false
      )

    commands = recorder |> Agent.get(& &1.commands) |> Enum.reverse()
    {result, commands}
  end

  defmodule SharedRecorderAdapter do
    @moduledoc "RecordingAdapter variant that reuses a caller-provided Agent."
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_context), do: :ok

    @impl true
    def execute(cmd, ctx, _runtime) do
      Agent.update(ctx.recorder, fn state ->
        %{state | commands: [cmd | state.commands]}
      end)

      case cmd do
        %CreateItem{} = c ->
          ref =
            Agent.get_and_update(ctx.recorder, fn state ->
              {"item_#{state.counter}", %{state | counter: state.counter + 1}}
            end)

          {:ok, [%ItemCreated{item_ref: ref, name: c.name, quantity: c.quantity}]}

        %ViewItem{} = c ->
          {:ok, [%ItemViewed{item_ref: c.item_ref}]}

        %MinimalCommand{} ->
          {:ok, []}
      end
    end
  end

  test "two runs with the same seed execute identical command sequences" do
    {result1, commands1} = run_and_record(424_242)
    {result2, commands2} = run_and_record(424_242)

    assert {:ok, _} = result1
    assert {:ok, _} = result2

    # The runs must have actually executed something non-trivial
    assert length(commands1) > 3

    assert commands1 == commands2
  end

  test "different seeds produce different command sequences" do
    {_result1, commands1} = run_and_record(1)
    {_result2, commands2} = run_and_record(999_999_937)

    refute commands1 == commands2
  end

  test "run_seed/2 is identity for run 0 and well-mixed afterwards" do
    assert Generator.run_seed(12_345, 0) == 12_345

    later = for n <- 1..50, do: Generator.run_seed(12_345, n)

    # Distinct across runs and distinct from the base seed
    assert length(Enum.uniq(later)) == 50
    refute 12_345 in later
  end

  test "generate_value/2 is a pure function of the seed" do
    generator = Generator.generate_sequence(FullModel, max_commands: 10)

    v1 = Generator.generate_value(generator, 7)
    v2 = Generator.generate_value(generator, 7)
    v3 = Generator.generate_value(generator, 8)

    assert v1 == v2
    refute v1 == v3
  end
end
